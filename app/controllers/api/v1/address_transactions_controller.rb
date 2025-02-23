require 'csv'
module Api
  module V1
    class AddressTransactionsController < ApplicationController
      before_action :validate_query_params
      before_action :validate_pagination_params, :pagination_params
      before_action :set_address_transactions, only: [:show, :download_csv]

      def show
        @address = Address.find_address!(params[:id])
        raise Api::V1::Exceptions::AddressNotFoundError if @address.is_a?(NullAddress)

        @tx_ids = AccountBook
          .joins(:ckb_transaction)
          .where(address_id: @address.id)

        params[:sort] ||= "ckb_transaction_id.desc"
        order_by, asc_or_desc = params[:sort].split('.', 2)
        order_by = case order_by
          when 'time' then 'ckb_transactions.block_timestamp'
          else order_by
        end

        head :not_found and return unless order_by.in? %w[ckb_transaction_id block_timestamp ckb_transactions.block_timestamp]

        @tx_ids = @tx_ids
          .order(order_by => asc_or_desc)
          .select("ckb_transaction_id")
          .page(@page).per(@page_size).fast_page

        order_by = 'id' if order_by == 'ckb_transaction_id'
        @ckb_transactions = CkbTransaction.tx_committed.where(id: @tx_ids.map(&:ckb_transaction_id))
          .select(:id, :tx_hash, :block_id, :block_number, :block_timestamp, :is_cellbase, :updated_at, :capacity_involved)
          .order(order_by => asc_or_desc)

        json =
          Rails.cache.realize("#{@ckb_transactions.cache_key}/#{@address.query_address}", version: @ckb_transactions.cache_version) do
            @options = FastJsonapi::PaginationMetaGenerator.new(request: request, records: @ckb_transactions, page: @page, page_size: @page_size, records_counter: @tx_ids).call
            json_result
          end

        render json: json
      end

      def download_csv
        tx_ids = AccountBook.where(address_id: @address.id).order("ckb_transaction_id" => :desc).select("ckb_transaction_id").limit(5000)
        ckb_transactions = CkbTransaction.where(id: tx_ids.map(&:ckb_transaction_id))
        ckb_transactions = ckb_transactions.where('ckb_transactions.block_timestamp >= ?', DateTime.strptime(params[:start_date], '%Y-%m-%d').to_time.to_i * 1000 ) if params[:start_date].present?
        ckb_transactions = ckb_transactions.where('ckb_transactions.block_timestamp <= ?', DateTime.strptime(params[:end_date], '%Y-%m-%d').to_time.to_i * 1000 ) if params[:end_date].present?
        ckb_transactions = ckb_transactions.where('block_number >= ?', params[:start_number]) if params[:start_number].present?
        ckb_transactions = ckb_transactions.where('block_number <= ?', params[:end_number]) if params[:end_number].present?

        ckb_transactions = ckb_transactions
          .select(:id, :tx_hash, :transaction_fee, :block_id, :block_number, :block_timestamp, :is_cellbase, :updated_at)
          .order(id: :desc)
          .limit(5000)

        file = CSV.generate do |csv|
          csv << ["TXn hash", "Blockno", "UnixTimestamp", "Method", "CKB In", "CKB OUT", "TxnFee(CKB)", "date(UTC)" ]
          ckb_transactions.each_with_index do |ckb_transaction, index|

            inputs = ckb_transaction.display_inputs
            outputs = ckb_transaction.display_outputs
            max = inputs.size > outputs.size ? inputs.size : outputs.size
            (0 .. max-1).each do |i|
              row = [ckb_transaction.tx_hash, ckb_transaction.block_number, ckb_transaction.block_timestamp, "Transfer",
                     (inputs[i][:capacity].to_d / 1e8 rescue '/'),
                     (outputs[i][:capacity].to_d / 1e8 rescue '/'),
                     ckb_transaction.transaction_fee, ckb_transaction.updated_at]
              csv << row
            end
          end
        end
        send_data file, :type => 'text/csv; charset=utf-8; header=present', :disposition => "attachment;filename=ckb_transactions.csv"
      end

      private

      def validate_query_params
        validator = Validations::Address.new(params)

        if validator.invalid?
          errors = validator.error_object[:errors]
          status = validator.error_object[:status]

          render json: errors, status: status
        end
      end

      def pagination_params
        @page = params[:page] || 1
        @page_size = params[:page_size] || CkbTransaction.default_per_page
      end

      def json_result
        ckb_transaction_serializer = CkbTransactionsSerializer.new(@ckb_transactions, @options.merge(params: { previews: true, address: @address }))

        if QueryKeyUtils.valid_address?(params[:id])
          if @address.address_hash == @address.query_address
            ckb_transaction_serializer.serialized_json
          else
            ckb_transaction_serializer.serialized_json.gsub(@address.address_hash, @address.query_address)
          end
        else
          ckb_transaction_serializer.serialized_json
        end
      end

      def set_address_transactions
        @address = Address.find_address!(params[:id])
        raise Api::V1::Exceptions::AddressNotFoundError if @address.is_a?(NullAddress)

      end

    end
  end
end
