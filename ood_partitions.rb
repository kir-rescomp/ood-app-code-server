# frozen_string_literal: true

# OodPartitions: partition list and partition metadata for an Open OnDemand
# Batch Connect app. Place this file in the app's root directory.
#
# Why the app builds its own partition list
#   OnDemand's `auto_queues` hides a partition unless one of the user's own
#   account names appears in its AllowAccounts. Slurm is more permissive: it
#   accepts a job when the job's account OR ANY PARENT ACCOUNT is listed
#   (slurmctld/partition_mgr.c, _find_acct_in_list). On BMRC the GPU
#   partitions allow parent accounts (gpu_kir, gpu_bmrc, ...), so auto_queues
#   hides all of them from users in, for example, gpu_kir.prj. This helper
#   applies Slurm's rule instead.
#
# What it provides (all cached for ten minutes per dashboard process)
#   options(cluster_id:)  select options of the partitions the user may use
#   to_json(cluster_id:)  per-partition { max_hours, gpu } for form.js
#   gpu?(name, ...)       whether a partition is a GPU partition
#
# A partition is a GPU partition when its TRES include gres/gpu or its name
# begins with "gpu". form.js and submit.yml.erb both use this rule.
#
# Usage in form.yml.erb / submit.yml.erb:
#   <%- require File.join(__dir__, 'ood_partitions') unless defined?(OodPartitions) -%>
#
# Changes to this file take effect after the user's dashboard (PUN) restarts.

require 'etc'
require 'json'
require 'open3'

module OodPartitions
  GPU_NAME  = /\Agpu/i.freeze
  CACHE_TTL = 600 # seconds
  UNLIMITED = %w[UNLIMITED INFINITE].freeze

  module_function

  # ---- Public interface -------------------------------------------------------

  # @param cluster_id [String, nil] the OnDemand cluster id (the form's
  #   `cluster:` value). When nil, the only job cluster is used.
  # @return [Array<Array(String, String)>] [[label, value], ...] in Slurm's
  #   configuration order. If the user's accounts cannot be read, every
  #   partition scontrol returns is listed rather than none.
  def options(cluster_id: nil)
    usable(cluster_id: cluster_id).map { |name| [name, name] }
  end

  # @return [String] JSON { partition => { max_hours, gpu } } for form.js
  def to_json(cluster_id: nil)
    info(cluster_id: cluster_id).transform_values do |meta|
      { 'max_hours' => meta['max_hours'], 'gpu' => meta['gpu'] }
    end.to_json
  end

  # @return [Boolean] whether the named partition is a GPU partition
  def gpu?(partition, cluster_id: nil)
    name = partition.to_s.strip
    return false if name.empty?

    meta = info(cluster_id: cluster_id)[name]
    meta.nil? ? GPU_NAME.match?(name) : meta['gpu']
  end

  # @return [Integer, nil] the partition's MaxTime in whole hours
  def max_hours(partition, cluster_id: nil)
    meta = info(cluster_id: cluster_id)[partition.to_s.strip]
    meta && meta['max_hours']
  end

  # ---- Partitions ----------------------------------------------------------------

  # @return [Array<String>] partitions the user may submit to
  def usable(cluster_id: nil)
    parts = info(cluster_id: cluster_id)
    lineages = account_lineages(cluster_id: cluster_id)
    return parts.keys if lineages.empty?

    parts.select { |_name, meta| allowed?(meta, lineages) }.keys
  end

  # Slurm's rule: with AllowAccounts, some account of the user (or one of its
  # parents) must be listed; otherwise some account of the user must have no
  # account in its lineage that is listed in DenyAccounts.
  # @param lineages [Array<Array<String>>] each user account followed by its parents
  def allowed?(meta, lineages)
    lineages.any? do |lineage|
      if meta['allow']
        (lineage & meta['allow']).any?
      else
        (lineage & (meta['deny'] || [])).empty?
      end
    end
  end

  # @return [Hash{String => Hash}] partition => { max_hours, gpu, allow, deny }
  def info(cluster_id: nil)
    cached(:partitions, cluster_id) { parse(slurm('scontrol', cluster_id, '--oneliner', 'show', 'partition')) }
  end

  # Parse `scontrol --oneliner show partition` output.
  def parse(text)
    text.to_s.each_line.with_object({}) do |line, partitions|
      line = line.strip
      next unless line.start_with?('PartitionName=')

      fields = line.split(/\s+(?=[A-Za-z][A-Za-z0-9_]*=)/).to_h { |kv| kv.split('=', 2) }
      name = fields['PartitionName'].to_s
      next if name.empty?

      partitions[name] = {
        'max_hours' => hours(fields['MaxTime']),
        'gpu'       => fields['TRES'].to_s.include?('gres/gpu') || GPU_NAME.match?(name),
        'allow'     => account_list(fields['AllowAccounts']),
        'deny'      => account_list(fields['DenyAccounts']) || []
      }
    end
  end

  # @return [Array<String>, nil] nil means ALL
  def account_list(value)
    str = value.to_s.strip
    return nil if str.empty? || str.casecmp?('ALL')

    str.split(',').map(&:strip).reject(&:empty?)
  end

  # Convert a Slurm time string ([D-]HH:MM:SS, HH:MM:SS, MM:SS, MM) to whole hours.
  # @return [Integer, nil] nil for UNLIMITED or an unparseable value
  def hours(value)
    str = value.to_s.strip
    return nil if str.empty? || UNLIMITED.include?(str.upcase)

    days, rest = str.include?('-') ? str.split('-', 2) : ['0', str]
    parts = rest.to_s.split(':')
    return nil unless ([days] + parts).all? { |p| p.match?(/\A\d+\z/) }

    h, m, s = if str.include?('-')
                [parts[0].to_i, parts[1].to_i, parts[2].to_i]
              else
                case parts.length
                when 3 then parts.map(&:to_i)
                when 2 then [0, parts[0].to_i, parts[1].to_i]
                else        [0, parts[0].to_i, 0]
                end
              end

    ((days.to_i * 86_400) + (h * 3600) + (m * 60) + s) / 3600
  end

  # ---- Accounts --------------------------------------------------------------------

  # @return [Array<Array<String>>] for each of the user's accounts, the account
  #   followed by its parent accounts up to the root
  def account_lineages(cluster_id: nil)
    cached(:lineages, cluster_id) do
      where = cluster_id ? ["cluster=#{cluster_id}"] : []
      user = Etc.getpwuid(Process.uid).name

      accounts = slurm('sacctmgr', cluster_id, '-nP', 'show', 'associations', 'format=account',
                       'where', "user=#{user}", *where)
                 .lines.map { |l| l.strip.delete('|') }.reject(&:empty?).uniq

      # Account-level associations (no user) carry each account's parent.
      parents = {}
      args = ['-nP', 'show', 'associations', 'format=account,user,parentname']
      args += ['where', *where] unless where.empty?
      slurm('sacctmgr', cluster_id, *args).each_line do |line|
        acct, usr, parent = line.strip.split('|', 3)
        next if acct.to_s.empty? || !usr.to_s.empty?

        parents[acct] = parent.to_s
      end

      accounts.map do |acct|
        lineage = [acct]
        while (parent = parents[lineage.last]) && !parent.empty? && !lineage.include?(parent)
          lineage << parent
        end
        lineage
      end
    end
  end

  # ---- Slurm commands ----------------------------------------------------------

  # Run a Slurm command as the dashboard user, honouring the cluster's `job:`
  # configuration (bin, bin_overrides, conf; cluster for scontrol).
  # @return [String] the command's output, or '' if it could not be run
  def slurm(cmd, cluster_id, *args)
    cfg = job_config(cluster_id)
    overrides = (cfg[:bin_overrides] || {}).transform_keys(&:to_s)
    bin = overrides[cmd] || (cfg[:bin] ? File.join(cfg[:bin].to_s, cmd) : cmd)
    args = ['--clusters', cfg[:cluster].to_s] + args if cmd == 'scontrol' && cfg[:cluster]
    env = cfg[:conf] ? { 'SLURM_CONF' => cfg[:conf].to_s } : {}

    out, status = Open3.capture2(env, bin.to_s, *args, err: File::NULL)
    status.success? ? out : ''
  rescue StandardError
    ''
  end

  # @return [Hash] the cluster's `job:` configuration from clusters.d, or {}
  def job_config(cluster_id)
    return {} unless defined?(OodAppkit) && OodAppkit.respond_to?(:clusters)

    clusters = OodAppkit.clusters
    cluster = cluster_id ? clusters[cluster_id.to_sym] : nil
    if cluster.nil?
      job_clusters = clusters.select(&:job_allow?)
      cluster = job_clusters.first if job_clusters.size == 1
    end
    cluster ? cluster.job_config.to_h : {}
  rescue StandardError
    {}
  end

  # Cache a non-empty result for CACHE_TTL seconds.
  def cached(kind, cluster_id)
    @cache ||= {}
    key = [kind, cluster_id.to_s]
    entry = @cache[key]
    return entry[:data] if entry && (Time.now - entry[:at]) < CACHE_TTL

    data = yield
    @cache[key] = { at: Time.now, data: data } unless data.empty?
    data
  end
end
