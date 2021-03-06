require "lsp"
require "./scry/log"
require "./scry/request"
require "./scry/context"
require "./scry/message"
require "./scry/environment_config"
require "./scry/client"

module Scry
  def self.start
    client = Client.new(STDOUT)

    Log.backend = ClientLogBackend.new(client)
    Log.info { "Scry is looking into your code..." }

    at_exit do
      Log.info { "...your session has ended" }
    end

    EnvironmentConfig.run

    context = Context.new
    loop do
      begin
        content = Request.new(STDIN).read
        request = Message.from(content)
        results = context.dispatch(request)
      rescue ex
        results = [LSP::Protocol::ResponseMessage.new(ex)]
      ensure
        response = [results].flatten.compact
        client.send_message(response)
      end
    end
  rescue ex
    Log.error(exception: ex) { %(#{ex.message || "Unknown error"}\n#{ex.backtrace.join('\n')}) } unless Log.nil?
  end
end

Scry.start
