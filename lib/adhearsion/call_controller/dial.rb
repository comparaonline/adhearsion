# encoding: utf-8

require 'countdownlatch'

module Adhearsion
  class CallController
    module Dial
      #
      # Dial one or more third parties and join one to this call
      #
      # @overload dial(to[String], options = {})
      #   @param [String] to The target URI to dial.
      #     You must specify a properly formatted string that your VoIP platform understands.
      #     eg. sip:foo@bar.com, tel:+14044754840, or SIP/foo/1234
      #   @param [Hash] options see below
      #
      # @overload dial(to[Array], options = {})
      #   @param [Array<String>] to Target URIs to dial.
      #     Each will be called with the same options simultaneously.
      #     The first call answered is joined, the others are hung up.
      #   @param [Hash] options see below
      #
      # @overload dial(to[Hash], options = {})
      #   @param [Hash<String => Hash>] to Target URIs to dial, mapped to their per-target options overrides.
      #     Each will be called with the same options simultaneously.
      #     The first call answered is joined, the others are hung up.
      #     Each calls options are deep-merged with the global options hash.
      #   @param [Hash] options see below
      #
      # @option options [String] :from the caller id to be used when the call is placed. It is advised you properly adhere to the
      #   policy of VoIP termination providers with respect to caller id values. Defaults to the caller ID of the dialing call, so for normal bridging scenarios, you do not need to set this.
      #
      # @option options [Numeric] :for this option can be thought of best as a timeout.
      #   i.e. timeout after :for if no one answers the call
      #
      # @option options [CallController] :confirm the controller to execute on the first outbound call to be answered, to give an opportunity to screen the call. The calls will be joined if the outbound call is still active after this controller completes.
      # @option options [Hash] :confirm_metadata Metadata to set on the confirmation controller before executing it. This is shared between all calls if dialing multiple endpoints; if you care about it being mutated, you should provide an immutable value (using eg https://github.com/harukizaemon/hamster).
      #
      # @example Make a call to the PSTN using my SIP provider for VoIP termination
      #   dial "SIP/19095551001@my.sip.voip.terminator.us"
      #
      # @example Make 3 simulataneous calls to the SIP extensions, try for 15 seconds and use the callerid for this call specified by the variable my_callerid
      #   dial %w{SIP/jay-desk-650 SIP/jay-desk-601 SIP/jay-desk-601-2}, :for => 15.seconds, :from => my_callerid
      #
      # @example Make a call using the IAX provider to the PSTN
      #   dial "IAX2/my.id@voipjet/19095551234", :from => "John Doe <9095551234>"
      #
      # @return [DialStatus] the status of the dial operation
      #
      def dial(to, options = {})
        dial = Dial.new to, options, call
        dial.run
        dial.await_completion
        dial.cleanup_calls
        dial.status
      end

      # Dial one or more third parties and join one to this call after execution of a confirmation controller.
      # Confirmation will be attempted on all answered calls, and calls will be allowed to progress through confirmation in parallel. The first to complete confirmation will be joined to the A-leg, with the others being hung up.
      #
      # @option options [CallController] :apology controller to execute on calls which lose the race to complete confirmation before they are hung up
      #
      # @see #dial
      def dial_and_confirm(to, options = {})
        dial = ParallelConfirmationDial.new to, options, call
        dial.run
        dial.await_completion
        dial.cleanup_calls
        dial.status
      end

      class Dial
        attr_accessor :status

        def initialize(to, options, call)
          raise Call::Hangup unless call.alive? && call.active?
          @options, @call = options, call
          @targets = to.respond_to?(:has_key?) ? to : Array(to)
          set_defaults
        end

        def set_defaults
          @status = DialStatus.new

          @latch = CountDownLatch.new @targets.size

          @options[:from] ||= @call.from

          _for = @options.delete :for
          @options[:timeout] ||= _for if _for

          @confirmation_controller = @options.delete :confirm
          @confirmation_metadata = @options.delete :confirm_metadata
        end

        def run
          track_originating_call
          prep_calls
          place_calls
        end

        def track_originating_call
          @call.on_end { |_| @latch.countdown! until @latch.count == 0 }
        end

        def prep_calls
          @calls = @targets.map do |target, specific_options|
            new_call = OutboundCall.new

            join_status = JoinStatus.new
            status.joins[new_call] = join_status

            new_call.on_end do |event|
              @latch.countdown! unless new_call["dial_countdown_#{@call.id}"]
              if event.reason == :error
                status.error!
                join_status.errored!
              end
            end

            new_call.on_answer do |event|
              pre_confirmation_tasks new_call

              new_call.on_unjoined @call do |unjoined|
                new_call["dial_countdown_#{@call.id}"] = true
                join_status.ended
                @latch.countdown!
              end

              if @confirmation_controller
                status.unconfirmed!
                join_status.unconfirmed!
                new_call.execute_controller @confirmation_controller.new(new_call, @confirmation_metadata), lambda { |call| call.signal :confirmed }
                new_call.wait :confirmed
              end

              if new_call.alive? && new_call.active? && status.result != :answer
                logger.debug "#dial joining call #{new_call.id} to #{@call.id}"
                pre_join_tasks new_call
                @call.answer
                join_status.started
                new_call.join @call
                status.answer!(new_call)
              elsif status.result == :answer
                logger.debug "Lost confirmation race"
                join_status.lost_confirmation!
              end
            end

            [new_call, target, specific_options]
          end

          status.calls = @calls
        end

        def place_calls
          @calls.map! do |call, target, specific_options|
            local_options = @options.dup.deep_merge specific_options if specific_options
            call.dial target, (local_options || @options)
            call
          end
        end

        def await_completion
          @latch.wait(@options[:timeout]) || status.timeout!
          @latch.wait if status.result == :answer
        end

        def cleanup_calls
          logger.debug "#dial finished. Hanging up #{@calls.size} outbound calls: #{@calls.map(&:id).join ", "}."
          @calls.each do |outbound_call|
            begin
              outbound_call.hangup
            rescue Celluloid::DeadActorError
              # This actor may previously have been shut down due to the call ending
            end
          end
        end

        private

        def pre_confirmation_tasks(call)
          on_all_except call do |target_call|
            logger.debug "#dial hanging up call #{target_call.id} because this call has been answered by another channel"
            target_call.hangup
          end
        end

        def pre_join_tasks(call)
        end

        def on_all_except(call)
          @calls.each do |target_call, _|
            begin
              next if target_call.id == call.id
              yield target_call
            rescue Celluloid::DeadActorError
              # This actor may previously have been shut down due to the call ending
            end
          end
        end
      end

      class ParallelConfirmationDial < Dial
        def set_defaults
          super
          @apology_controller = @options.delete :apology
        end

        private

        def pre_confirmation_tasks(call)
        end

        def pre_join_tasks(call)
          on_all_except call do |target_call|
            if @apology_controller
              logger.debug "#dial apologising to call #{target_call.id} because this call has been answered by another channel"
              target_call.async.execute_controller @apology_controller.new(target_call, @confirmation_metadata), ->(call) { call.hangup }
            else
              logger.debug "#dial hanging up call #{target_call.id} because this call has been answered by another channel"
              target_call.hangup
            end
          end
        end
      end

      class DialStatus
        # The collection of calls created during the dial operation
        attr_accessor :calls, :joined_call

        # A collection of status objects indexed by call. Provides status on the joins such as duration
        attr_accessor :joins

        # @private
        def initialize
          @result = nil
          @joins = {}
        end

        #
        # The result of the dial operation.
        #
        # @return [Symbol] :no_answer, :answer, :timeout, :error
        def result
          @result || :no_answer
        end

        # @private
        def answer!(call)
          @joined_call = call
          @result = :answer
        end

        # @private
        def timeout!
          @result ||= :timeout
        end

        # @private
        def error!
          @result ||= :error
        end

        # @private
        def unconfirmed!
          @result ||= :unconfirmed
        end
      end

      class JoinStatus
        # The time at which the calls were joined
        attr_accessor :start_time

        # Time at which the join was broken
        attr_accessor :end_time

        def initialize
          @result = :no_answer
        end

        # The result of the attempt to join calls
        # Can be:
        # * :joined - The calls were sucessfully joined
        # * :no_answer - The attempt to dial the third-party was cancelled before they answered
        # * :unconfirmed - The callee did not complete confirmation
        # * :lost_confirmation - The callee completed confirmation, but was beaten by another
        # * :error - The call ended with some error
        attr_reader :result

        # The duration for which the calls were joined. Does not include time spent in confirmation controllers or after being separated.
        def duration
          if start_time && end_time
            end_time - start_time
          else
            0.0
          end
        end

        def errored!
          @result = :error
        end

        def unconfirmed!
          @result = :unconfirmed
        end

        def lost_confirmation!
          @result = :lost_confirmation
        end

        def started
          @start_time = Time.now
          @result = :joined
        end

        def ended
          @end_time = Time.now
        end
      end

    end
  end
end
