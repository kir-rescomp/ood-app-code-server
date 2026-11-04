// form.js: GPU partition behaviour for Open OnDemand 4.x Batch Connect apps.
// Replaces the app's previous form.js; OnDemand loads only a file of this name.
//
// When the selected partition is a GPU partition:
//   - the "GPU Slurm account" field (attribute `gpu_account`) is shown and
//     made required; otherwise it is hidden and not required. Its value is
//     kept, so switching partitions does not lose it; submit.yml.erb uses it
//     only for GPU partitions.
// For every partition:
//   - the "Number of hours" field (`bc_num_hours`) is limited to the
//     partition's MaxTime, and its help text states the limit.
//
// Partition limits and GPU flags come from Slurm, through the JSON that
// form.yml.erb places on the partition select as `data-partitions`
// (see ood_partitions.rb). New partitions therefore need no change here.
// If that data is missing, a partition whose name begins with "gpu" is
// treated as a GPU partition and the hours limit is left as configured.
//
// Written for OnDemand 4.x markup: each field is wrapped in
// `<div id="batch_connect_session_context_<attr>_wrapper">`, and hidden with
// Bootstrap 5's `d-none` class (Bootstrap 3's `.form-group` no longer exists).

(function () {
  'use strict';

  const PREFIX = 'batch_connect_session_context_';
  const GPU_NAME = /^gpu/i;

  const field = (attr) => document.getElementById(PREFIX + attr);
  const wrapper = (attr) => document.getElementById(PREFIX + attr + '_wrapper');

  // The partition select: `partition` (built by the app from Slurm, see
  // ood_partitions.rb), or OnDemand's own auto_queues / bc_queue.
  const partitionSelect = field('partition') || field('auto_queues') || field('bc_queue');
  if (!partitionSelect) return;

  let partitions = {};
  try {
    partitions = JSON.parse(partitionSelect.dataset.partitions || '{}') || {};
  } catch (e) {
    partitions = {};
  }

  // Help text element of a field: bootstrap_form renders
  // <small class="form-text text-muted"> after the input.
  function helpElement(attr, create) {
    const wrap = wrapper(attr);
    if (!wrap) return null;
    let help = wrap.querySelector('.form-text');
    if (!help && create) {
      const input = field(attr);
      if (!input) return null;
      help = document.createElement('small');
      help.className = 'form-text text-muted';
      input.insertAdjacentElement('afterend', help);
    }
    return help;
  }

  function isGpuPartition(name) {
    const meta = partitions[name];
    return meta ? Boolean(meta.gpu) : GPU_NAME.test(name || '');
  }

  function updateGpuAccount(name) {
    const input = field('gpu_account');
    const wrap = wrapper('gpu_account');
    if (!input || !wrap) return;

    const gpu = isGpuPartition(name);
    wrap.classList.toggle('d-none', !gpu);
    input.required = gpu;
    input.setAttribute('aria-required', gpu ? 'true' : 'false');
  }

  function updateHours(name) {
    const input = field('bc_num_hours');
    if (!input) return;

    // Remember the configured maximum and help text, so that a partition
    // without a MaxTime restores them.
    if (input.dataset.configuredMax === undefined) {
      input.dataset.configuredMax = input.getAttribute('max') || '';
      const help = helpElement('bc_num_hours', false);
      input.dataset.configuredHelp = help ? help.innerHTML : '';
    }

    const meta = partitions[name];
    const maxHours = meta && meta.max_hours ? parseInt(meta.max_hours, 10) : null;
    const configuredMax = input.dataset.configuredMax;

    if (maxHours) {
      input.setAttribute('max', String(maxHours));
    } else if (configuredMax) {
      input.setAttribute('max', configuredMax);
    } else {
      input.removeAttribute('max');
    }

    const limit = parseInt(input.getAttribute('max'), 10);
    const current = parseInt(input.value, 10);
    if (!Number.isNaN(limit) && !Number.isNaN(current) && current > limit) {
      input.value = String(limit);
    }

    if (maxHours) {
      const help = helpElement('bc_num_hours', true);
      if (help) {
        help.textContent =
          'Maximum runtime in hours for the session. The ‘' + name +
          '’ partition allows up to ' + maxHours + ' hour' +
          (maxHours === 1 ? '' : 's') + '.';
      }
    } else {
      const help = helpElement('bc_num_hours', false);
      if (help) help.innerHTML = input.dataset.configuredHelp || '';
    }
  }

  function update() {
    const name = partitionSelect.value;
    updateGpuAccount(name);
    updateHours(name);
  }

  // OnDemand's own scripts (saved settings, dynamic forms) change the select
  // with jQuery's trigger('change'), which native listeners do not receive,
  // so the handler is bound through jQuery when it is available.
  if (window.jQuery) {
    window.jQuery(partitionSelect).on('change', update);
    window.jQuery(update);
  } else {
    partitionSelect.addEventListener('change', update);
    document.addEventListener('DOMContentLoaded', update);
  }
  update();
}());
