module Toshi
  module Models
    class RawAuxPow < Sequel::Model

      def bitcoin_aux_pow
        Bitcoin::P::AuxPow.new(payload)
      end
    end
  end
end
