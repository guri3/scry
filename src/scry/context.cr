require "./analyzer"
require "./workspace"
require "./formatter"
require "./initializer"
require "./implementations"
require "./update_config"
require "./parse_analyzer"
require "./publish_diagnostic"
require "./symbol"
require "./completion_provider"
require "./completion_resolver"
require "./hover_provider"

module Scry
  class_property shutdown = false

  class UnrecognizedProcedureError < Exception
  end

  class InvalidRequestError < Exception
  end

  struct Context
    def initialize
      @workspace = Workspace.new("", 0, 0)
    end

    # A request message to describe a request between the client and the server.
    # Every processed request must send a response back to the sender of the request.
    def dispatch(msg : LSP::Protocol::RequestMessage)
      Log.debug { msg.method }
      dispatch_request(msg.params, msg)
    end

    def dispatch(msg : LSP::Protocol::NotificationMessage)
      Log.debug { msg.method }
      dispatch_notification(msg.params, msg)
    end

    private def dispatch_request(params : Nil, msg)
      if msg.method == "shutdown"
        Scry.shutdown = true
        LSP::Protocol::ResponseMessage.new(msg.id, nil)
      end
    end

    private def dispatch_notification(params : Nil, msg)
      if msg.method == "exit"
        exit(0)
      end
    end

    private def dispatch_request(params : LSP::Protocol::InitializeParams, msg)
      initializer = Initializer.new(params, msg.id)
      @workspace, response = initializer.run
      response
    end

    # Also used by methods like Go to Definition
    private def dispatch_request(params : LSP::Protocol::TextDocumentPositionParams, msg)
      case msg.method
      when "textDocument/hover"
        text_document = TextDocument.new(params, msg.id)
        return ignore_path_response(msg.id, text_document) if text_document.in_memory?
        hover = HoverProvider.new(@workspace, text_document)
        response = hover.run
        Log.debug { response }
        response
      when "textDocument/definition"
        text_document = TextDocument.new(params, msg.id)
        return ignore_path_response(msg.id, text_document) if text_document.in_memory?
        definitions = Implementations.new(@workspace, text_document)
        response = definitions.run
        Log.debug { response }
        response
      when "textDocument/completion"
        text_document, method_db = @workspace.get_file(TextDocument.uri_to_filename(params.text_document.uri))
        return ignore_path_response(msg.id, text_document) if text_document.in_memory?
        completion = CompletionProvider.new(text_document, params.context, params.position, method_db)
        results = completion.run
        response = LSP::Protocol::ResponseMessage.new(msg.id, results)
        Log.debug { response }
        response
      else
        raise UnrecognizedProcedureError.new("Didn't recognize procedure: #{msg.method}")
      end
    end

    private def dispatch_request(params : LSP::Protocol::DocumentFormattingParams, msg)
      text_document = TextDocument.new(params, msg.id)

      if open_file = @workspace.open_files[text_document.filename]?
        text_document.text = open_file.first.text
      end

      formatter = Formatter.new(@workspace, text_document)
      response = formatter.run
      Log.debug { response }
      response
    end

    private def dispatch_request(params : LSP::Protocol::TextDocumentParams, msg)
      case msg.method
      when "textDocument/documentSymbol"
        text_document = TextDocument.new(params, msg.id)
        return ignore_path_response(msg.id, text_document) if text_document.in_memory?
        symbol_processor = SymbolProcessor.new(text_document)
        symbols = symbol_processor.run
        response = LSP::Protocol::ResponseMessage.new(msg.id, symbols)
        Log.debug { response }
        response
      end
    end

    private def dispatch_request(params : LSP::Protocol::WorkspaceSymbolParams, msg)
      case msg.method
      when "workspace/symbol"
        workspace_symbol_processor = WorkspaceSymbolProcessor.new(@workspace.root_uri, params.query)
        symbols = workspace_symbol_processor.run
        response = LSP::Protocol::ResponseMessage.new(msg.id, symbols)
        Log.debug { response }
        response
      end
    end

    private def dispatch_request(params : LSP::Protocol::CompletionItem, msg)
      case msg.method
      when "completionItem/resolve"
        resolver = CompletionResolver.new(msg.id, params)
        results = resolver.run
        response = LSP::Protocol::ResponseMessage.new(msg.id, results)
        Log.debug { response }
        response
      end
    end

    # Used by:
    # - `textDocument/didSave`
    # - `textDocument/didClose`
    private def dispatch_notification(params : LSP::Protocol::TextDocumentParams, msg)
      case msg.method
      when "textDocument/didClose"
        @workspace.drop_file(TextDocument.new(params))
      end
      nil
    end

    private def dispatch_notification(params : LSP::Protocol::DidChangeConfigurationParams, msg)
      updater = UpdateConfig.new(@workspace, params)
      @workspace, response = updater.run
      response
    end

    private def dispatch_notification(params : LSP::Protocol::DidOpenTextDocumentParams, msg)
      text_document = TextDocument.new(params)
      return ignore_path_response(nil, text_document) if text_document.in_memory?
      @workspace.put_file(text_document)
      unless text_document.in_memory?
        analyzer = Analyzer.new(@workspace, text_document)
        response = analyzer.run
        response
      end
    end

    private def dispatch_notification(params : LSP::Protocol::DidChangeTextDocumentParams, msg)
      text_document = TextDocument.new(params)
      return ignore_path_response(nil, text_document) if text_document.in_memory?
      @workspace.update_file(text_document)
      analyzer = ParseAnalyzer.new(@workspace, text_document)
      response = analyzer.run
      response
    end

    private def dispatch_notification(params : LSP::Protocol::DidChangeWatchedFilesParams, msg)
      params.changes.map { |file_event|
        handle_file_event(file_event)
      }.compact
    end

    private def handle_file_event(file_event : LSP::Protocol::FileEvent)
      text_document = TextDocument.new(file_event)

      case file_event.type
      when LSP::Protocol::FileEventType::Created
        analyzer = Analyzer.new(@workspace, text_document)
        response = analyzer.run
        response
      when LSP::Protocol::FileEventType::Deleted
        PublishDiagnostic.new(@workspace, text_document.uri).full_clean
      when LSP::Protocol::FileEventType::Changed
        @workspace.reopen_workspace(text_document)
        analyzer = Analyzer.new(@workspace, text_document)
        response = analyzer.run
        response
      end
    end

    private def dispatch_notification(params, msg)
      nil
    end

    private def ignore_path_response(msg_id : Int32?, text_document : TextDocument) : LSP::Protocol::ResponseMessage?
      Log.debug { "Ignoring path: #{text_document.filename}" }
      if msg_id
        LSP::Protocol::ResponseMessage.new(msg_id, nil)
      else # Notification messages don't require a response
        nil
      end
    end
  end
end
