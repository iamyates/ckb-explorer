class CkbUtils
  def self.calculate_cell_min_capacity(output, data)
    output.calculate_min_capacity(data)
  end

  def self.block_cell_consumed(transactions)
    transactions.reduce(0) do |memo, transaction|
      outputs_data = transaction.outputs_data
      transaction.outputs.each_with_index do |output, cell_index|
        memo += calculate_cell_min_capacity(output, outputs_data[cell_index])
      end
      memo
    end
  end

  def self.total_cell_capacity(transactions)
    transactions.flat_map(&:outputs).reduce(0) { |memo, output| memo + output.capacity.to_i }
  end

  def self.miner_hash(cellbase)
    return if cellbase.witnesses.blank?

    lock_script = generate_lock_script_from_cellbase(cellbase)
    generate_address(lock_script)
  end

  def self.miner_lock_hash(cellbase)
    return if cellbase.witnesses.blank?

    lock_script = generate_lock_script_from_cellbase(cellbase)
    lock_script.compute_hash
  end

  def self.generate_lock_script_from_cellbase(cellbase)
    witnesses_data = cellbase.witnesses.first.data
    hash_type = witnesses_data.first[-2..-1] == "00" ? "data" : "type"
    CKB::Types::Script.new(code_hash: witnesses_data.first[0..-3], args: [witnesses_data.last], hash_type: hash_type)
  end

  def self.generate_address(lock_script)
    if use_default_lock_script?(lock_script)
      short_payload_blake160_address(lock_script)
    else
      code_hash = lock_script.code_hash
      args = lock_script.args
      format_type = lock_script.hash_type == "data" ? "0x02" : "0x04"
      first_arg = args.first

      return if args.blank? || !args.all? { |arg| CKB::Utils.valid_hex_string?(arg) }

      CKB::Address.new(first_arg).generate_full_payload_address(format_type, code_hash, args)
    end
  end

  def self.short_payload_blake160_address(lock_script)
    blake160 = lock_script.args.first
    return if blake160.blank? || !CKB::Utils.valid_hex_string?(blake160)

    CKB::Address.new(blake160).generate
  end

  def self.use_default_lock_script?(lock_script)
    code_hash = lock_script.code_hash
    hash_type = lock_script.hash_type
    correct_code_match = "#{ENV["CODE_HASH"]}data"
    correct_type_match = "#{ENV["SECP_CELL_TYPE_HASH"]}type"

    return false if code_hash.blank?

    "#{code_hash}#{hash_type}".in?([correct_code_match, correct_type_match])
  end

  def self.parse_address(address_hash)
    CKB::Address.parse(address_hash)
  end

  def self.block_reward(node_block_header)
    cellbase_output_capacity_details = CkbSync::Api.instance.get_cellbase_output_capacity_details(node_block_header.hash)
    primary_reward(node_block_header, cellbase_output_capacity_details) + secondary_reward(node_block_header, cellbase_output_capacity_details)
  end

  def self.base_reward(block_number, epoch_number, cellbase = nil)
    return cellbase.outputs.first.capacity.to_i if block_number.to_i == 0 && cellbase.present?

    epoch_info = get_epoch_info(epoch_number)
    start_number = epoch_info.start_number.to_i
    epoch_reward = ENV["DEFAULT_EPOCH_REWARD"].to_i
    base_reward = epoch_reward / epoch_info.length.to_i
    remainder_reward = epoch_reward % epoch_info.length.to_i
    if block_number.to_i >= start_number && block_number.to_i < start_number + remainder_reward
      base_reward + 1
    else
      base_reward
    end
  end

  def self.primary_reward(node_block_header, cellbase_output_capacity_details)
    node_block_header.number.to_i != 0 ? cellbase_output_capacity_details.primary.to_i : 0
  end

  def self.secondary_reward(node_block_header, cellbase_output_capacity_details)
    node_block_header.number.to_i != 0 ? cellbase_output_capacity_details.secondary.to_i : 0
  end

  def self.get_epoch_info(epoch)
    CkbSync::Api.instance.get_epoch_by_number(epoch)
  end

  def self.ckb_transaction_fee(ckb_transaction)
    if ckb_transaction.inputs.dao.present?
      dao_withdraw_tx_fee(ckb_transaction)
    else
      normal_tx_fee(ckb_transaction)
    end
  end

  def self.get_unspent_cells(address_hash)
    return if address_hash.blank?

    address = Address.find_by(address_hash: address_hash)
    address.cell_outputs.live
  end

  def self.get_balance(address_hash)
    return if address_hash.blank?

    get_unspent_cells(address_hash).sum(:capacity)
  end

  def self.address_cell_consumed(address_hash)
    return if address_hash.blank?

    address_cell_consumed = 0
    get_unspent_cells(address_hash).find_each do |cell_output|
      address_cell_consumed += calculate_cell_min_capacity(cell_output.node_output, cell_output.data)
    end

    address_cell_consumed
  end

  def self.update_block_reward!(current_block)
    target_block_number = current_block.target_block_number
    target_block = current_block.target_block
    return if target_block_number < 1 || target_block.blank?

    block_header = Struct.new(:hash, :number)
    cellbase_output_capacity_details = CkbSync::Api.instance.get_cellbase_output_capacity_details(current_block.block_hash)
    reward = CkbUtils.block_reward(block_header.new(current_block.block_hash, current_block.number))
    primary_reward = CkbUtils.primary_reward(block_header.new(current_block.block_hash, current_block.number), cellbase_output_capacity_details)
    secondary_reward = CkbUtils.secondary_reward(block_header.new(current_block.block_hash, current_block.number), cellbase_output_capacity_details)
    target_block.update!(reward_status: "issued", reward: reward, primary_reward: primary_reward, secondary_reward: secondary_reward)
    current_block.update!(target_block_reward_status: "issued")
  end

  def self.calculate_received_tx_fee!(current_block)
    target_block_number = current_block.target_block_number
    target_block = current_block.target_block
    return if target_block_number < 1 || target_block.blank?

    cellbase = Cellbase.new(current_block)
    proposal_reward = cellbase.proposal_reward
    commit_reward = cellbase.commit_reward
    received_tx_fee = commit_reward + proposal_reward
    target_block.update!(received_tx_fee: received_tx_fee, received_tx_fee_status: "calculated")
  end

  def self.update_current_block_miner_address_pending_rewards(miner_address)
    Address.increment_counter(:pending_reward_blocks_count, miner_address.id, touch: true) if miner_address.present?
  end

  def self.update_target_block_miner_address_pending_rewards(current_block)
    target_block_number = current_block.target_block_number
    target_block = current_block.target_block
    return if target_block_number < 1 || target_block.blank?

    miner_address = target_block.miner_address
    Address.decrement_counter(:pending_reward_blocks_count, miner_address.id, touch: true) if miner_address.present?
  end

  def self.normal_tx_fee(ckb_transaction)
    ckb_transaction.inputs.sum(:capacity) - ckb_transaction.outputs.sum(:capacity)
  end

  def self.dao_withdraw_tx_fee(ckb_transaction)
    dao_cells = ckb_transaction.inputs.dao
    witnesses = ckb_transaction.witnesses
    header_deps = ckb_transaction.header_deps
    interests =
      dao_cells.reduce(0) do |memo, dao_cell|
        witness = witnesses[dao_cell.cell_index]
        block_hash = header_deps[witness["data"].last.hex]
        out_point = CKB::Types::OutPoint.new(tx_hash: dao_cell.tx_hash, index: dao_cell.cell_index)

        memo + CkbSync::Api.instance.calculate_dao_maximum_withdraw(out_point, block_hash).to_i - dao_cell.capacity.to_i
      end

    ckb_transaction.inputs.sum(:capacity) + interests - ckb_transaction.outputs.sum(:capacity)
  rescue CKB::RPCError
    0
  end
end
