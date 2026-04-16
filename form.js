// Map partition names to their time limits in hours
const partitionMaxHours = {
  "short":               30,   // 1-06:00:00
  "long":               240,   // 10-00:00:00
  "himem":              240,
  "gpu_interactive":     12,
  "gpu_p100_16gb":       60,
  "gpu_v100_16gb":       60,
  "gpu_v100_32gb":       60,
  "gpu_a100_40gb":       60,
  "gpu_a100_80gb":       60,
  "gpu_rtx8000_48gb":    60,
  "gpu_gh200_144gb":     60,
  "relion":             240,
  "fraser":             240,
  "brcgel":             240,
  "win":                240,
  "cloudcomp":          240,
};

function updateMaxHours() {
  const partition  = $("#batch_connect_session_context_auto_queues").val();
  const maxHours   = partitionMaxHours[partition] || 240;
  const hoursField = $("#batch_connect_session_context_bc_num_hours");

  hoursField.attr("max", maxHours);

  const currentVal = parseInt(hoursField.val(), 10);
  if (currentVal > maxHours) {
    hoursField.val(maxHours);
  }

  hoursField.closest(".form-group")
    .find(".form-text")
    .text(
      `Maximum runtime in hours for your session. ` +
      `The '${partition}' partition allows up to ${maxHours} hour(s).`
    );
}

function updateGpuAccountField() {
  const partition       = $("#batch_connect_session_context_auto_queues").val();
  const isGpu           = partition.startsWith("gpu_");
  const gpuAccountGroup = $("#batch_connect_session_context_gpu_account")
                            .closest(".form-group");

  if (isGpu) {
    gpuAccountGroup.show();
    $("#batch_connect_session_context_gpu_account").attr("required", true);
  } else {
    gpuAccountGroup.hide();
    $("#batch_connect_session_context_gpu_account")
      .removeAttr("required")
      .val("");
  }
}

$(document).ready(function () {
  updateMaxHours();
  updateGpuAccountField();

  $("#batch_connect_session_context_auto_queues").on("change", function () {
    updateMaxHours();
    updateGpuAccountField();
  });
});
