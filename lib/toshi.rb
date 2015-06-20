require 'bitcoin'
require 'erb'
require 'logger'
require 'yaml'
require 'toshi/version'

module Toshi
  # core.h: CTransaction::CURRENT_VERSION
  CURRENT_TX_VERSION = 1

  # main.h
  MAX_STANDARD_TX_SIZE = 100000

  # satoshis per kb, main.cpp: CFeeRate CTransaction::minRelayTxFee = CFeeRate(1000);
  MIN_RELAY_TX_FEE = 1000

  # postgresql advisory lock ids
  module Lock
    MEMPOOL             = 1
    PROCESS_TRANSACTION = 2
    PROCESS_BLOCK       = 3
  end

  autoload :BlockHeaderIndex,   'toshi/block_header_index'
  autoload :BlockchainStorage,  'toshi/blockchain_storage'
  autoload :Bootstrap,          'toshi/bootstrap'
  autoload :ConnectionHandler,  'toshi/connection_handler'
  autoload :PeerManager,        'toshi/peer_manager'
  autoload :Logging,            'toshi/logging'
  autoload :MemoryPool,         'toshi/memory_pool'
  autoload :OutputsCache,       'toshi/outputs_cache'
  autoload :Processor,          'toshi/processor'

  module Models
    autoload :Address,                    'toshi/models/address'
    autoload :AddressSettings,            'toshi/models/address_settings'
    autoload :Block,                      'toshi/models/block'
    autoload :Input,                      'toshi/models/input'
    autoload :Output,                     'toshi/models/output'
    autoload :Peer,                       'toshi/models/peer'
    autoload :RawAuxPow,                  'toshi/models/raw_aux_pow'
    autoload :RawBlock,                   'toshi/models/raw_block'
    autoload :RawTransaction,             'toshi/models/raw_transaction'
    autoload :Transaction,                'toshi/models/transaction'
    autoload :UnconfirmedAddress,         'toshi/models/unconfirmed_address'
    autoload :UnconfirmedInput,           'toshi/models/unconfirmed_input'
    autoload :UnconfirmedOutput,          'toshi/models/unconfirmed_output'
    autoload :UnconfirmedRawTransaction,  'toshi/models/unconfirmed_raw_transaction'
    autoload :UnconfirmedTransaction,     'toshi/models/unconfirmed_transaction'
  end

  def self.env
    @env ||= (ENV['TOSHI_ENV'] || ENV['RACK_ENV'] || 'development').to_sym
  end

  def self.root
    @root ||= File.expand_path('../..', __FILE__)
  end

  def self.settings
    @settings ||= begin
      config_file = [
        "#{root}/config/toshi.yml",
        "#{root}/config/toshi.yml.example"
      ].find { |f| File.exists?(f) }

      settings = {}
      YAML.load(ERB.new(File.read(config_file)).result)[env.to_s].each do |key, value|
        settings[key.to_sym] = value
      end

      settings[:debug] = true # TODO: remove once logging is cleaned up

      Bitcoin.network = settings[:network] # TODO: where should this live?

      settings
    end
  end

  def self.logger
    @logger ||= begin
      logger = Logger.new(STDOUT)

      # set log level
      level = settings[:log_level].to_s.upcase
      logger.level = Logger.const_get(level).to_i rescue 1

      # slightly nicer default format
      logger.formatter = proc do |severity, time, progname, msg|
        "#{time.utc.iso8601(3)} #{::Process.pid} #{progname} #{severity}: #{msg}\n"
      end

      logger
    end
  end

  def self.logger=(logger)
    @logger = logger
  end
end

require "toshi/db"
require "toshi/mq"
require "toshi/utils"
require "toshi/workers/block_worker"
require "toshi/workers/transaction_worker"
