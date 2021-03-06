# @(#) MQMBID sn=mqkoa-L160208.09 su=_Zdh2gM49EeWAYJom138ZUQ pn=appmsging/ruby/mqlight/lib/mqlight/blocking_client.rb
#
# <copyright
# notice="lm-source-program"
# pids="5725-P60"
# years="2014,2016"
# crc="3568777996" >
# Licensed Materials - Property of IBM
#
# 5725-P60
#
# (C) Copyright IBM Corp. 2014, 2016
#
# US Government Users Restricted Rights - Use, duplication or
# disclosure restricted by GSA ADP Schedule Contract with
# IBM Corp.
# </copyright>
#

require 'thread'
require 'securerandom'
require 'uri'
require 'timeout'

module Mqlight
  #
  # The MQ Light client.  This can be used to exchange messages between 
  # the MQ AMQP Channel or MQ Light server.  This version of the client 
  # blocks the calling thread while carrying out messaging operations.
  #
  # @note this class uses timeouts in milliseconds with zero meaning: "don't
  #       wait at all" and nil meaning "wait forever - don't time out".
  class BlockingClient
    include Qpid::Proton::Util::ErrorHandler
    include Mqlight::Logging

    # @return [String] the client id, which can either be explicitly specified
    #         when the client is created or automatically generated.
    attr_reader :id

    # Creates a new instance of the client.  The client will be created in
    # starting state. The constructor will make a connection attempt to the
    # server and report failures (such as "not authorised") as
    # exceptions.  This means that in the golden path case the constructor
    # will return an instance of the BlockingClient that is in started state.
    # A code block, yielded to by the constructor can be used to register a
    # listener that receives notifications when the associated client changes
    # state.
    #
    # @param service [Array, String] a String containing the URL for the service
    #   to connect to, or alternatively an Array containing a list of URLs to
    #   attempt to connect to in turn. User names and passwords may be embedded
    #   into the URL (e.g. amqp://user:pass@host).
    # @option options [String] :id a unique identifier for this client. A
    #   maximum of one instance of the client (as identified by the value
    #   of this property) can be connected the an MQ Light server at a given
    #   point in time. If another instance of the same client connects, then
    #   the previously connected instance will be disconnected. This is
    #   reported, to the first client, as a ReplacedError being emitted as an
    #   error event and the client transitioning into stopped state. If the id
    #   property is not a valid client identifier (e.g. it contains a colon,
    #   it is too long, or it contains some other forbidden character) then
    #   the function will throw an ArgumentError exception.  If this option is
    #   not specified, a probabilistically unique value will be generated by the
    #   client.
    # @option options [String] :user user name for authentication.
    #   Alternatively, the user name may be embedded in the URL passed via the
    #   service property. If you choose to specify a user name via this
    #   property and also embed a user name in the URL passed via the surface
    #   argument, all the user names must match otherwise an ArgumentError
    #   exception will be thrown. User names and passwords must be specified
    #   together (or not at all). If you specify just the user property but no
    #   password property an ArgumentError exception will be thrown.
    # @option options [String] :password password for authentication.
    #   Alternatively, user name may be embedded in the URL passed via the
    #   service property.
    # @option options [String] :ssl_trust_certificate 
    #   Name of the file containing the trust certificate (in PEM format) to
    #   validate the identity of the server. The connection must be secured
    #   with SSL/TLS. This option and the :ssl_keystore option are mutually 
    #   exclusive. 
    # @option options [String] :ssl_client_certificate
    #   Name of the file containing the client key (in PEM format) to supply the
    #   identity of the client. The connection must be secured with SSL/TLS.
    #   Option is mutually exclusive with :ssl_keystore 
    # @option options [String] :ssl_client_key
    #   Name of the file containing the private key (in PEM format) for
    #   encrypting the specified client certificate. The connection must be
    #   secured with SSL/TLS. This option and the :ssl_keystore option are 
    #   mutually exclusive. 
    # @option options [String] :ssl_client_key_passphrase
    #   The passphrase for the ssl_client_key file
    # @option options [String] :ssl_keystore
    #   Name of the file containing the keystore (in PKCS#12 format) to supply
    #   the client certificate, private key and trust certificates. The 
    #   connection must be secured with This option and the following group of 
    #   options are mutually exclusive :ssl_client_key, :ssl_client_certificate
    #   and :ssl_trust_certifcate options.
    # @option options [String] :ssl_keystore_passphrase
    #    The passphrase for the :ssl_keystore file.
    # @option options [Boolean] :ssl_verify_name whether or not to additionally
    #   check that the MQ Light server's common name in the certificate matches
    #   the actual server's DNS name. Used only when the ssl_trust_certificate
    #   option is specified.  The default is true.
    #
    # @yield an optional block of code that is called into each time a
    #        transition occurs in the state machine underpinning the client.
    # @yieldparam state [Symbol] the state that the client has now transitioned
    #             into.  This will be one of: :starting, :started:, :stopping,
    #             :stopped, :retrying, :restarted.
    # @yieldparam reason [Exception, nil] an indication of why the client
    #             transitioned into this state.  An Exception is passed back
    #             when the client encounters an exception which causes it to
    #             transition into a new state.  A value of nil indicates that
    #             the client transitioned into this state either automatically
    #             or as a result of the user invoking the start or stop
    #             methods.
    #
    # @return [BlockingClient] the newly created instance of the client.
    #
    # @raise [ArgumentError] if one of the arguments supplied to the method
    #   is not valid.
    # @raise [SecurityError] if, during the construction process of the
    #   client, the MQ Light server rejects the client's connection attempt
    #   for a security related reason.
    #
    def initialize(service, options = {}, &state_callback)
      logger.entry(@id) { self.class.to_s + '#' + __method__.to_s }
      parms = Hash[method(__method__).parameters.map do |parm|
        [parm[1], eval(parm[1].to_s)]
      end]
      logger.parms(@id, parms) { self.class.to_s + '#' + __method__.to_s }

      @id = options.fetch(:id, nil)
      @user = options.fetch(:user, nil)
      @password = options.fetch(:password, nil)

      # Validate id
      fail ArgumentError, 'Client identifier must be a String.' unless
        @id.is_a?(String) || @id.nil?

      set_defaults

      # Create the variables to share between the threads.
      @thread_vars = Mqlight::ThreadVars.new(@id)

      # Validate id some more
      fail ArgumentError, "Client identifier '#{@id}' is longer than the "\
        'maximum ID length of 256.' if @id.length > 256

      # currently client ids are restricted, reject any invalid ones
      invalid_client_id_pattern = %r{[^A-Za-z0-9%\/\._]+}
      invalid_client_id_pattern.match(@id) do |m|
        fail ArgumentError, "Client Identifier '#{@id}' contains invalid "\
          "char: #{m[0]}"
      end

      # Validate username and password
      fail ArgumentError, 'Both user and password properties must '\
                          'be specified together.' if
        (@user && !@password) || (!@user && @password)

      if @user && @password
        fail ArgumentError, 'Both user and password must be Strings.' unless
          (@user.is_a? String) && (@password.is_a? String)
      end

      # pre-validate service param is a well-formed URI
      Util.validate_services(service, @user, @password)

      @thread_vars.state_callback = state_callback

      # Setup queue for sharing with proton thread
      @proton_queue = Queue.new
      @proton_queue_mutex = Mutex.new
      @proton_queue_resource = ConditionVariable.new

      args = {
        options: options,
        id: @id,
        user: @user,
        password: @password,
        service: service,
        thread_vars: @thread_vars,
      }
      @command = Mqlight::Command.new(args)
      @connection = Mqlight::Connection.new(args)

      logger.data(@id, 'Client created. Starting...') do
        self.class.to_s + '#' + __method__.to_s
      end
      start
      logger.exit(@id) { self.class.to_s + '#' + __method__.to_s }
    rescue StandardError => e
      logger.throw(@id, e) { self.class.to_s + '#' + __method__.to_s }
      raise e
    end

    # Requests that the client transition into started state.  This method will
    # block the calling thread until the client has either:
    # 1. Attained started state (effectively being a no-op if the client is
    #    already in started state)
    # 2. Attained stopped state (most likely due to another thread calling the
    #    stop method before the client manages to attain started state).
    #
    # @option options [nil, Numeric] :timeout the period of time (in
    #   milliseconds) to wait for the client to attain started state. If the
    #   client does not attain started state in this period of time a
    #   TimeoutError exception will be thrown by this method and the client
    #   will continue to transition in state, as defined by its underlying
    #   state machine. A value of zero is interpreted as time out immediately
    #   if the client is not already in started state. A value of nil (the
    #   default) is interpreted as never time out.
    #
    # @return [BlockingClient] the instance of the client that the send method
    #   was invoked upon.  This allows for method chaining.
    #
    # @raise [RangeError] if the value specified via the timeout option is
    #   outside of the range of valid values.
    # @raise [StoppedError] if the client transitions into stopped state before
    #   attaining started state.
    # @raise [TimeoutError] if a timeout value is specified and the client does
    #   not transition into started state within this period of time.
    def start(_options = {})
      logger.entry(@id) { self.class.to_s + '#' + __method__.to_s }
      parms = Hash[method(__method__).parameters.map do |parm|
        [parm[1], eval(parm[1].to_s)]
      end]
      logger.parms(@id, parms) { self.class.to_s + '#' + __method__.to_s }
      logger.exit(@id) { self.class.to_s + '#' + __method__.to_s } \
        unless stopped?

      return unless stopped?  # TODO: missing exit trace
      @thread_vars.change_state(:starting)

      # Try each service in turn
      logger.data(@id, 'Trying each service in turn') do
        self.class.to_s + '#' + __method__.to_s
      end

      # New connection; increment count
      @thread_vars.reconnected

      # Start the command thread
      @command.start_thread

      # Proton handle thread.
      @connection.start_thread

      @callback_thread = Thread.new do
        Thread.current['name'] = 'callback_thread'
        callback_loop until stopped? && @thread_vars.callback_queue.empty?
      end

      logger.data(@id, 'Waiting for state change') do
        self.class.to_s + '#' + __method__.to_s
      end

      # Block until the state changes
      sleep(0.1) until retrying? || started? || stopped?

      fail @thread_vars.last_state_error if stopped?

      logger.exit(@id, self) { self.class.to_s + '#' + __method__.to_s }
      self

    rescue StandardError => e
      logger.throw(@id, e) { self.class.to_s + '#' + __method__.to_s }
      raise e
    end

    # Requests that the client transition into stopped state. This method will
    # block the calling thread until the client has attained stopped state.
    #
    # @raise [RangeError] if the value specified via the timeout option is
    #        outside of the range of valid values.
    # @raise [TimeoutError] if a timeout value is specified and the client does
    #        not flush any buffered messages within the timeout period. The
    #        client will, however, still transition to stopped state even if
    #        this exception is thrown.
    def stop(options = {})
      logger.entry(@id) { self.class.to_s + '#' + __method__.to_s }
      parms = Hash[method(__method__).parameters.map do |parm|
        [parm[1], eval(parm[1].to_s)]
      end]
      logger.parms(@id, parms) { self.class.to_s + '#' + __method__.to_s }

      unless stopped?
        if started?
           @thread_vars.change_state(:stopping)
           @thread_vars.proton.stop
        end
        @thread_vars.change_state(:stopped)
        @thread_vars.subscriptions_clear
        @connection.wakeup
        @connection.stop_thread
        @command.join
      end

      logger.exit(@id) { self.class.to_s + '#' + __method__.to_s }
    rescue StandardError => e
      logger.throw(@id, e) { self.class.to_s + '#' + __method__.to_s }
      raise e
    end

    # Sends a message to the specified topic, blocking the calling thread while
    # the send operation takes place (or until the timeout value, as specified
    # via the timeout option is exceeded).
    # * For "at most once" quality of service messages (qos option set to 0),
    #   the calling thread will block until the client is both
    #   successfully network connected and the message has been buffered
    #   by the client.  This method may or may not block until the data has
    #   been flushed to the underlying network, at the discretion of the
    #   client implementation, which balances throughput against buffering
    #   large amounts of data.
    # * For "at least once" quality of service messages (qos option set to 1),
    #   the calling thread will block until the client is both
    #   successfully network connected and has received confirmation
    #   from the server that the server has received a copy of the message.
    #
    # @param topic [String] the topic to which the message will be sent.
    # @param data [String] the data to send in the message payload.
    # @option options [Numeric] :qos The quality of service to use when
    #   sending the message. 0 is used to denote at most once (the default)
    #   and 1 is used for at least once. If a value which is not 0 and not 1
    #   is specified then this method will throw a RangeError exception.
    # @option options [nil, Numeric] :timeout the minimum amount
    #   of time (in milliseconds) that the client will attempt to send
    #   the message for.  If the client is not able to send the message
    #   after this period has elapsed then this method will raise
    #   TimeoutError. A value of zero is interpreted as timeout
    #   immediately.  A value of nil (the default) means wait indefinitely.
    # @option options [Numeric] :ttl A time to live value for the message in
    #   milliseconds. MQ Light will endeavour to discard, without delivering,
    #   any copy of the message that has not been delivered within its time to
    #   live period. The default time to live is 604800000 milliseconds
    #   (7 days). The value supplied for this argument must be greater than
    #   zero and finite, otherwise a RangeError exception will be thrown when
    #   this method is called.
    #
    # @return [BlockingClient] the instance of the client that the send method
    #   was invoked upon.  This allows for method chaining.
    #
    # @raise [ArgumentError] if one of the arguments supplied to the method is
    #   not valid.
    # @raise [TimeoutError] if the amount of time taken to process the send
    #   request has exceeded the value specified by the timeout option. If
    #   the send operation is sending a QoS 0 message then the message will
    #   not have been sent. If a QoS 1 message is being sent then the message
    #   may have been sent to the server, but not as yet acknowledged by
    #   the server.
    # @raise [StoppedError] if the method is called while the client is in
    #   stopped state, or has transitioned into stopped state while the send
    #   operation was taking place.
    def send(topic, data, options = {})
      logger.entry(@id) { self.class.to_s + '#' + __method__.to_s }
      parms = Hash[method(__method__).parameters.map do |parm|
        [parm[1], eval(parm[1].to_s)]
      end]
      logger.parms(@id, parms) { self.class.to_s + '#' + __method__.to_s }

      fail Mqlight::StoppedError, 'Not started.' if stopped?
      fail ArgumentError, 'topic must be a String' unless topic.is_a? String
      fail Mqlight::UnsupportedError, "#{data.class.name.split('::').last} "\
        'is not yet supported as a message data type' unless data.is_a? String

      if options.is_a? Hash
        qos = options.fetch(:qos, nil)
        ttl = options.fetch(:ttl, nil)
        timeout = options.fetch(:timeout, nil)
      else
        fail ArgumentError, 'options must be a Hash.' unless options.nil?
      end
      qos ||= QOS_AT_MOST_ONCE

      @thread_vars.proton.settle_mode = qos

      unless ttl.nil?
        fail ArgumentError,
             "options:ttl value '" + ttl.to_s +
               "' is invalid, must be an unsigned non-zero integer number" \
               unless ttl.is_a?(Integer) && ttl > 0
        ttl = 4_294_967_295 if ttl > 4_294_967_295
      end

      if timeout
        fail ArgumentError, 'timeout must be nil or a unsigned Integer' if
          (!timeout.is_a? Integer) || (timeout < 0)
        timeout /= 1000.0
      end

      # Setup the message
      msg = Qpid::Proton::Message.new

      # URI escape anything apart from path separators (/) and all known
      # unreserved characters
      msg.address = @thread_vars.service.address + '/' + topic
      msg.ttl = ttl if ttl

      msg.body = data
      if data.encoding == Encoding::BINARY
        msg.content_type = 'application/octet-stream'
      else
        begin
          JSON.parse(data)
          msg.content_type = 'application/json'
        rescue JSON::ParserError
          msg.content_type = 'text/plain'
        end
      end
      msg.pre_encode

      # Clear the return queue
      @thread_vars.reply_queue.clear

      begin
        @command.push_request(action: 'send', params: msg.impl,
                              qos: qos, timeout: timeout)

        # Collect the reply
        reply = @thread_vars.reply_queue.pop
        fail reply unless reply.nil?

        logger.exit(@id, self) { self.class.to_s + '#' + __method__.to_s }
        self

      rescue StandardError => e
        logger.throw(@id, e) { self.class.to_s + '#' + __method__.to_s }
        raise e
      end
    end

    # Subscribes to receive messages from a destination, identified by the
    # topic pattern argument. The receive(...) method can then be used to
    # retrieve messages, held at the server, for the destination.
    # The client cannot be in stopped or stopping state when this method is
    # called, otherwise a StoppedError will be raised.
    #
    # @param topic_pattern [String] the topic pattern to subscribe to.  This
    #        identifies or creates a destination.
    # @option options [Boolean] :auto_confirm when set to true (the default) the
    #         client will automatically confirm delivery of messages when all of
    #         the listeners registered for the client's message event have
    #         returned. When set to false, application code is responsible for
    #         confirming the delivery of messages using the confirm
    #         method, passed via the delivery argument of the listener
    #         registered for message events. auto_confirm is only applicable
    #         when the qos property is set to 1. The qos property is described
    #         later.
    # @option options [Numeric] :qos the quality of service to use for
    #         delivering messages to the subscription. Valid values are: 0 to
    #         denote at most once (the default), and 1 for at least once. A
    #         RangeError will be thrown for other values.
    # @option options [Numeric] :ttl a time-to-live value, in milliseconds, that
    #         is applied to the destination that the client is subscribed to.
    #         This value will replace any previous value, if the destination
    #         already exists. Time to live starts counting down when there are
    #         no instances of a client subscribed to a destination. It is reset
    #         each time a new instance of the client subscribes to the
    #         destination. If time to live counts down to zero then MQ Light
    #         will delete the destination by discarding any messages held at
    #         the destination and not accruing any new messages. The default
    #         value for this property is 0 - which means the destination will be
    #         deleted as soon as there are no clients subscribed to it.
    # @option options [String] :share the name for creating or joining a shared
    #         destination for which messages are anycast between connected
    #         subscribers. If omitted, defaults to a private destination (e.g.
    #         messages can only be received by a specific instance of the
    #         client).
    # @raise [StoppedError] if the method is called while the client is in the
    #        stopped state.
    # @raise [SubscribedError] if the client is already subscribed to the
    #        destination.
    def subscribe(topic_pattern, options = {})
      logger.entry(@id) { self.class.to_s + '#' + __method__.to_s }
      parms = Hash[method(__method__).parameters.map do |parm|
        [parm[1], eval(parm[1].to_s)]
      end]
      logger.parms(@id, parms) { self.class.to_s + '#' + __method__.to_s }

      fail Mqlight::StoppedError, 'Not started.' if stopped?
      destination = Mqlight::Destination.new(@thread_vars.service,
                                             topic_pattern,
                                             options)

      @thread_vars.proton.settle_mode = destination.qos

      timeout = options.nil? ? nil : options.fetch(:timeout, nil)
      @command.push_request(action: 'subscribe', params: destination,
                            timeout: timeout)

      # Collect status and throw exception is present
      reply = @thread_vars.reply_queue.pop
      fail reply unless reply.nil?
      logger.exit(@id, self) { self.class.to_s + '#' + __method__.to_s }
      self
    rescue StandardError => e
      logger.throw(@id, e) { self.class.to_s + '#' + __method__.to_s }
      raise e
    end

    # Receive a message from a destination, as identified by the topic pattern
    # used to subscribe to the destination.
    # @param topic_pattern [String] a topic pattern identifying the
    #        destination to attempt to receive messages from.  The destination
    #        must previously have been subscribed to using the subscribe method.
    #        This method will block the calling thread until at least one
    #        message is received from the destinations or the operation times
    #        out (see the timeout option).
    # @option options [nil, Numeric] :timeout the period of time
    #         (in milliseconds) to wait for a message to be received from at
    #         least one of the destinations. If no messages are received from
    #         any of the destinations within this time period, then nil is
    #         returned.
    #         A value of < 10 is interpreted as minimum time out of
    #         10 milliseconds.
    #         A value of nil (the default) is intepreted as never timeout.
    # @return (Delivery, nil) either a delivery object - representing the
    #         message received or nil if no message was received (e.g. because
    #         the operation timed out).
    # @raise [StoppedError] if the client is in stopped or stopping state.  This
    #        can also occur because another thread calls the stop method while
    #        a thread is blocked inside this receive method.
    # @raise [UnsubscribedError] if one or more of the topic_patterns refers to
    #        a destination that the client not currently subscribed to.
    #        This can also occur because another thread calls the unsubscribe
    #        method while a thread is blocked inside this receive method.
    def receive(topic_pattern, options = {})
      logger.entry(@id) { self.class.to_s + '#' + __method__.to_s }
      parms = Hash[method(__method__).parameters.map do |parm|
        [parm[1], eval(parm[1].to_s)]
      end]
      logger.parms(@id, parms) { self.class.to_s + '#' + __method__.to_s }

      fail Mqlight::StoppedError, 'Not started.' if stopped?

      # Validate topic_pattern
      fail ArgumentError, 'topic_pattern must be a String.' unless
        topic_pattern.is_a? String

      # Validate options
      fail ArgumentError, 'options must be a Hash.' unless
        options.is_a?(Hash) || options.nil?

      timeout = options.fetch(:timeout, nil) if options.is_a? Hash
      unless timeout.nil?
        fail ArgumentError, 'timeout must be nil or an unsigned Integer' unless
          timeout.is_a? Integer
        fail RangeError, 'timeout must be an unsigned Integer' if
          timeout < 0
        timeout /= 1000.0
        # minimum timeout is 10 milliseconds. This is a mimimum practical.
        timeout = 0.010 if timeout == 0
      end

      share = options.fetch(:share, nil)
      fail ArgumentError, 'share must be a String or nil.' unless
        share.is_a?(String) || share.nil?
      if share.is_a? String
        fail ArgumentError,
             'share is invalid because it contains a colon (:) character' if
               share.include? ':'
      end

      logger.data(@id, 'Checking for a matching destination') do
        self.class.to_s + '#' + __method__.to_s
      end
      destination = @thread_vars.destinations.find do |dest|
        dest.match?(topic_pattern, share)
      end
      # Has a matching destination has been found?
      if destination.nil?
        fail Mqlight::UnsubscribedError, 'You must be subscribed with '\
          "topic_pattern #{topic_pattern} to receive messages from it." \
          if share.nil?
        fail Mqlight::UnsubscribedError, 'You must be subscribed with '\
          "topic_pattern #{topic_pattern} and share #{share} to receive"\
          'messages from it.'
      end

      @command.push_request(action: 'receive',
                            timeout: timeout,
                            destination: destination)

      # Get the message or nil for timeout to return
      message = @thread_vars.reply_queue.pop

      # If the reply is an exception and that exception is
      # exception = timeout set message to nil to indicate timeout no message
      # otherwise raise the exception
      if message.is_a? Mqlight::ExceptionContainer
        if message.exception.is_a? Mqlight::TimeoutError
          message = nil
        else
          fail message.exception
        end
      end

      logger.exit(@id) { self.class.to_s + '#' + __method__.to_s }
      message
    rescue StandardError => e
      logger.throw(@id, e) { self.class.to_s + '#' + __method__.to_s }
      raise e
    end

    # Unsubscribes from a destination.  The client will no longer be able to
    # receive messages from the destination.  If another thread is using the
    # receive() methods to retrieve messages from the destination that is being
    # unsubscribed from then the receive() method will return immediately
    # raising an UnsubscribedError.
    #
    # @param topic_pattern [String] the topic pattern to unsubscribe from.
    #        This identifies the destination to unsubscribe from.
    # @option options [Numeric] :ttl sets the destination's time to live as part
    #         of the unsubscribe operation. The default (when this property is
    #         not specified) is not to change the destination's time to live.
    #         When specified the only valid value for this property is 0.
    # @option options [String] :share matched against the share specified on the
    #         subscribe call to determine which destination the client will
    #         unsubscribed from.
    # @raise [StoppedError] if the client is in stopped or stopping state.
    # @raise [UnsubscribedError] if the client is not subscribed to the
    #        destination (e.g. there has been no matching call to the subscribe
    #        method).
    #
    def unsubscribe(topic_pattern, options = {})
      logger.entry(@id) { self.class.to_s + '#' + __method__.to_s }
      parms = Hash[method(__method__).parameters.map do |parm|
        [parm[1], eval(parm[1].to_s)]
      end]
      logger.parms(@id, parms) { self.class.to_s + '#' + __method__.to_s }

      fail Mqlight::StoppedError, 'Not started' unless started?
      fail ArgumentError,
           'topic_pattern must be a String' unless topic_pattern.is_a? String
      @topic_pattern = topic_pattern

      share = options[:share]
      fail ArgumentError, 'share must be a String or nil.' unless
        share.is_a?(String) || share.nil?
      if share.is_a? String
        fail ArgumentError,
             'share is invalid because it contains a colon (:) character' if
               share.include? ':'
      end

      ttl = options[:ttl]
      fail ArgumentError, 'ttl value can only be 0' unless ttl.nil? || ttl == 0

      logger.data(@id, 'Checking for a matching destination') do
        self.class.to_s + '#' + __method__.to_s
      end
      destination = @thread_vars.destinations.find do |dest|
        dest.match? topic_pattern, share
      end
      fail Mqlight::UnsubscribedError,
           'client is not subscribed to this address and share' if
        destination.nil? && !share.nil?
      fail Mqlight::UnsubscribedError,
           'client is not subscribed to this address' if destination.nil?

      @command.push_request(action: 'unsubscribe', params: destination,
                            ttl: ttl)

      @thread_vars.destinations.delete(destination)
      logger.exit(@id, self) { self.class.to_s + '#' + __method__.to_s }
      self
    rescue StandardError => e
      logger.throw(@id, e) { self.class.to_s + '#' + __method__.to_s }
      raise e
    end

    # @return [nil, String] either the URL of the service that the client is
    #         currently connect to, or nil if the client is not currently
    #         connected to a service.
    def service
      @thread_vars.service.service if started?
    end

    # @return [Symbol] the current state of the client.  This will be one of:
    #         :starting, :started, :stopping, :stopped, :retrying, or :restarted
    def state
      @thread_vars.state
    end

    # @return [String] client Id
    def to_s
      "#{@id}"
    end

    # @return [Boolean] true indicating if the client is in the started status
    def started?
      @thread_vars.state == :started
    end

    # @return [Boolean] true indicating if the client is in the stopped status
    def stopped?
      @thread_vars.state == :stopped
    end

    # @return [Boolean] true indicating if the client is in the retrying status
    def retrying?
      @thread_vars.state == :retrying
    end

    # @return [Boolean] true indicating if the client is in the starting status
    def starting?
      @thread_vars.state == :starting
    end

    # @private
    def set_defaults
      logger.entry(@id) { self.class.to_s + '#' + __method__.to_s }

      # Generate id if none supplied
      @id ||= 'AUTO_' + SecureRandom.hex[0..6]

      logger.exit(@id) { self.class.to_s + '#' + __method__.to_s }
    rescue StandardError => e
      logger.throw(@id, e) { self.class.to_s + '#' + __method__.to_s }
      raise e
    end

    # @private
    def callback_loop
      logger.entry(@id) { self.class.to_s + '#' + __method__.to_s }

      argv = @thread_vars.callback_queue.pop
      callback = argv.shift
      # Catch any user generated errors from call back
      begin
        callback.call(argv)
      rescue StandardError => e
        logger.throw(@id, e) { self.class.to_s + '#' + __method__.to_s }
        $stderr.puts "*** Error: Call back generated error \'#{e}\'"
        $stderr.puts e.backtrace
      end
      logger.exit(@id) { self.class.to_s + '#' + __method__.to_s }
    rescue StandardError => e
      logger.ffdc(self.class.to_s + '#' + __method__.to_s,
                  'ffdc001', self, 'Uncaught exception', e)
    end
    # End of class
  end
end
