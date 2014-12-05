require 'faye/websocket'

module Toshi
  module Web
    class WsApiError < StandardError
    end

    # Websockets Rack Middleware
    class WebSockets
      attr_accessor :mq_client, :connections
      attr_reader :chan

      def ensure_reactor_running
        @reactor = Thread.new { EM.run } unless EM.reactor_running?
      end

      def initialize(app)
        ensure_reactor_running
        @app = app

        @connections = []
        @chan = { addresses: EM::Channel.new, blocks: EM::Channel.new, transactions: EM::Channel.new }

        # client channel listening for processor messages
        @mq_client = RedisMQ::Channel.new(:client){|sender, job|
          case job['msg']
          when 'new_block'
            @chan[:blocks].push(job)
          when 'new_transaction'
            @chan[:transactions].push(job)
            @chan[:addresses].push(job)
          end
        }

        @mq_client.init_heartbeat
        @mq_client.init_poll
      end

      def handle_websocket(env)
        connection = Toshi::Web::WebSocketConnection.new(env, self)
        connection.socket.rack_response
      end

      def call(env)
        if ::Faye::WebSocket.websocket?(env)
          handle_websocket(env)
        else
          @app.call(env)
        end
      end
    end

    # WebSocket Faye Connection Handler
    class WebSocketConnection
      attr_reader :socket

      def initialize(env, connection_manager)
        @channel_subscriptions = {}

        @socket = ::Faye::WebSocket.new(env)
        @socket.onmessage = method(:on_message)
        @socket.onclose   = method(:on_close)
        #p [:open, @socket.url, @socket.version, @socket.protocol]

        @connection_manager = connection_manager
        @connection_manager.connections << self

        @addresses = {}
      end

      def on_close(event)
        #p [:close, event.code, event.reason]
        @connection_manager.chan.keys.each{|channel_name| unsubscribe_channel(channel_name) }
        @connection_manager.connections.delete(self)
        @socket = nil
      end

      def on_message(event)
        begin
          cmd = JSON.parse(event.data)
          raise "parse error" if cmd.nil?
        rescue Exception => e
          #p [:message, event]
          @socket.send({ message_received: event.data }.to_json)
          return nil
        end

        begin
          if cmd.key?('subscribe')
            case cmd['subscribe']
              when 'address'
                raise WsApiError, 'no address specified' unless cmd.key?('address')

                address = cmd['address']
                raise WsApiError, 'invalid address' unless Bitcoin::valid_address?(address)
                raise WsApiError, 'unsupported address type' unless Bitcoin::address_type(address) == :hash160

                @addresses[address] = true
                subscribe_channel(:addresses, :on_channel_send_transaction_address)
              when 'blocks'
                subscribe_channel(:blocks, :on_channel_send_block)
              when 'transactions'
                subscribe_channel(:transactions, :on_channel_send_transaction)
              else
                raise WsApiError, "unknown subscription"
            end
          end

          if cmd.key?('unsubscribe')
            case cmd['unsubscribe']
              when 'address'
                raise WsApiError, 'no address specified' unless cmd.key?('address')
                address = cmd['address']
                raise WsApiError, 'invalid address' unless Bitcoin::valid_address?(address)

                @addresses.delete(address)
                if @addresses.empty?
                  unsubscribe_channel(:addresses)
                end
              when 'blocks'
                unsubscribe_channel(:blocks)
              when 'transactions'
                unsubscribe_channel(:transactions)
              else
                raise WsApiError, "unknown subscription"
            end
          end

          if cmd.key?('fetch')
            case cmd['fetch']
              when 'latest_block'
                on_fetch_latest_block()
              when 'latest_transaction'
                on_fetch_latest_transaction
              else
                raise WsApiError, 'unknown entity type'
            end
          end
        rescue Toshi::Web::WsApiError => e
          puts e.to_s
          @socket.send({ error: e.to_s }.to_json)
          return nil
        end
      end

      def write_socket(data)
        @socket.send(data) if @socket
      end

      # send a block to a connected websocket
      def on_channel_send_block(msg)
        block = Toshi::Models::Block.where(hsh: msg['hash']).first
        return unless block
        write_socket({ subscription: 'blocks', data: block.to_hash }.to_json)
      end

      # send a transaction if it matches address(es) this socket is interested in
      def on_channel_send_transaction_address(msg)
        tx = Toshi::Models::UnconfirmedTransaction.from_hsh(msg['hash'])
        return unless tx

        in_matches = []
        out_matches = []

        tx.outputs.each do |output|
          if output.type == 'hash160'
            script = Bitcoin::Script.new(output.script)
            address = script.get_hash160_address
            if @addresses.key?(address)
              out_matches << address
            end
          end
        end

        tx.previous_outputs.each do |output|
          if output.type == 'hash160'
            script = Bitcoin::Script.new(output.script)
            address = script.get_hash160_address
            if @addresses.key?(address)
              in_matches << address
            end
          end
        end
        return if in_matches.empty? && out_matches.empty?

        write_socket({ subscription: 'address', in_matches: in_matches, out_matches: out_matches, data: tx.to_hash }.to_json)
      end

      # send a transaction to a connected websocket
      def on_channel_send_transaction(msg)
        tx = Toshi::Models::UnconfirmedTransaction.from_hsh(msg['hash'])
        return unless tx
        write_socket({ subscription: 'transactions', data: tx.to_hash }.to_json)
      end

      def on_fetch_latest_block
        block = Toshi::Models::Block.head
        return unless block
        write_socket({ fetched: 'latest_block', data: block.to_hash }.to_json)
      end

      def on_fetch_latest_transaction
        tx = Toshi::Models::UnconfirmedTransaction.first
        return unless tx
        write_socket({ fetched: 'latest_transaction', data: tx.to_hash }.to_json)
      end

      def subscribe_channel(channel_name, method_name)
        @channel_subscriptions[channel_name] ||= @connection_manager.chan[channel_name].subscribe(&method(method_name))
      end

      def unsubscribe_channel(channel_name)
        if @channel_subscriptions[channel_name]
          @connection_manager.chan[channel_name].unsubscribe(@channel_subscriptions[channel_name])
          @channel_subscriptions[channel_name] = nil
        end
      end
    end

  end
end
