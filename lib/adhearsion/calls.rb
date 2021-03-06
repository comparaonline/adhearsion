# encoding: utf-8

module Adhearsion
  ##
  # This manages the list of calls the Adhearsion service receives
  class Calls < Hash
    include Celluloid

    trap_exit :call_died

    def <<(call)
      link call
      self[call.id] = call
      by_uri[call.uri] = call
      current_actor
    end

    def remove_inactive_call(call)
      if call_is_dead?(call)
        call_id = key call
        delete call_id if call_id

        remove_call_uri call
      elsif call.respond_to?(:id)
        delete call.id
        remove_call_uri call
      else
        call_actor = delete call
        remove_call_uri call_actor
      end
    end

    def with_tag(tag)
      values.find_all do |call|
        call.tagged_with? tag
      end
    end

    def with_uri(uri)
      by_uri[uri]
    end

    private

    def by_uri
      @by_uri ||= {}
    end

    def remove_call_uri(call)
      uri = by_uri.key call
      by_uri.delete uri if uri
    end

    def call_is_dead?(call)
      !call.alive?
    rescue NoMethodError
      false
    end

    def call_died(call, reason)
      catching_standard_errors do
        call_id = key call
        remove_inactive_call call
        return unless reason
        Adhearsion::Events.trigger :exception, reason
        logger.error "Call #{call_id} terminated abnormally due to #{reason}. Forcing hangup."
        PunchblockPlugin.client.execute_command Punchblock::Command::Hangup.new, :async => true, :call_id => call_id
      end
    end
  end
end
