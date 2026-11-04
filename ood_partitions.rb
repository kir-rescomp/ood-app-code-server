# frozen_string_literal: true

# OodPartitions: shared partition metadata for Open OnDemand Batch Connect apps.
#
# Reads `scontrol show partition` once (cached for ten minutes per dashboard
# process) and provides, for every partition:
#   - max_hours: the partition's MaxTime in whole hours (nil when UNLIMITED)
#   - gpu:       whether the partition is a GPU partition
#
# A partition is treated as a GPU partition when its TRES include gres/gpu, or
# when its name begins with "gpu" (for sites where GPUs are not tracked as
# TRES). The same rule is used by the form (through the JSON passed to the
# browser) and by submit.yml.erb, so both always agree.
#
# Place this file in the app's root directory, next to form.yml.erb.
# Usage in form.yml.erb / submit.yml.erb:
#   <%- require File.join(__dir__, 'ood_partitions') unless defined?(OodPartitions) -%>
#   <%= OodPartitions.to_json.to_json %>
#   <%- if OodPartitions.gpu?(auto_queues) -%> ... <%- end -%>
#
# Changes to this file take effect after the user's dashboard (PUN) restarts.

require 'json'
require 'open3'

module OodPartitions
  GPU_NAME   = /\Agpu/i.freeze
  CACHE_TTL  = 600 # seconds
  UNLIMITED  = %w[UNLIMITED INFINITE].freeze

  module_function

  # @param cluster_id [String, Symbol, nil] the OnDemand cluster id (the
  #   clusters.d file name). When nil, the only job cluster is used.
  # @return [Hash{String => Hash}] partition name => { 'max_hours', 'gpu' }
  def info(cluster_id: nil)
    @cache ||= {}
    key = cluster_id.to_s
    entry = @cache[key]
    return entry[:data] if entry && (Time.now - entry[:at]) < CACHE_TTL

    data = parse(scontrol_output(cluster_id))
    @cache[key] = { at: Time.now, data: data } unless data.empty?
    data
  end

  # @return [String] JSON for the browser (see gpu_partition_form.js)
  def to_json(cluster_id: nil)
    info(cluster_id: cluster_id).to_json
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

  # Parse `scontrol --oneliner show partition` output.
  # @param text [String]
  # @return [Hash{String => Hash}]
  def parse(text)
    text.to_s.each_line.with_object({}) do |line, partitions|
      line = line.strip
      next unless line.start_with?('PartitionName=')

      fields = line.split(/\s+(?=[A-Za-z][A-Za-z0-9_]*=)/).to_h { |kv| kv.split('=', 2) }
      name = fields['PartitionName'].to_s
      next if name.empty?

      partitions[name] = {
        'max_hours' => hours(fields['MaxTime']),
        'gpu'       => fields['TRES'].to_s.include?('gres/gpu') || GPU_NAME.match?(name)
      }
    end
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

  # Run scontrol as the dashboard user, honouring the cluster's job
  # configuration (bin, bin_overrides, conf, cluster) where it is available.
  # @return [String] scontrol output, or '' if it could not be run
  def scontrol_output(cluster_id)
    cfg = job_config(cluster_id)
    overrides = (cfg[:bin_overrides] || {}).transform_keys(&:to_s)
    bin = overrides['scontrol'] ||
          (cfg[:bin] ? File.join(cfg[:bin].to_s, 'scontrol') : 'scontrol')

    args = ['--oneliner']
    args += ['--clusters', cfg[:cluster].to_s] if cfg[:cluster]
    args += %w[show partition]
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
end
