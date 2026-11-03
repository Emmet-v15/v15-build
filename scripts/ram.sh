# The RAM rule for builds on this PC (sourced by local.sh and test.sh):
# cargo gets floor((free GB - 6) / 1.5) jobs, at least 1, and 1 while another
# build (rustc, cargo, java, gradle) runs. v15_jobs sets free, busy and jobs
# and exports CARGO_BUILD_JOBS.
v15_jobs() {
  free=$(powershell -NoProfile -Command "[math]::Floor((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB * 10) / 10" | tr -d '\r')
  jobs=$(awk -v f="$free" 'BEGIN { j = int((f - 6) / 1.5); print (j < 1 ? 1 : j) }')
  busy=$(tasklist 2> /dev/null | grep -ciE "^(rustc|cargo|java|gradle)" || true)
  [ "$busy" = 0 ] || jobs=1
  export CARGO_BUILD_JOBS=$jobs
}
