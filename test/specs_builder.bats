load test_helper

setup() { source_script; }

@test "build_review_specs emits repo/pr/branch/slug/since per survivor" {
  local s1=$'roofstock\totto-leases-service\t265\tdc2354f\tLRX-9992-branch\tabc1234\thttps://github.com/roofstock/otto-leases-service/pull/265'
  run build_review_specs "$s1"
  [ "$status" -eq 0 ]
  [ "$output" = $'otto-leases-service\t265\tLRX-9992-branch\troofstock/otto-leases-service\tabc1234' ]
}

@test "build_review_specs keeps empty since field (first review)" {
  local s1=$'roofstock\totto-leases-service\t265\tdc2354f\tLRX-9992-branch\t\thttps://github.com/roofstock/otto-leases-service/pull/265'
  run build_review_specs "$s1"
  [ "$status" -eq 0 ]
  [ "$output" = $'otto-leases-service\t265\tLRX-9992-branch\troofstock/otto-leases-service\t' ]
}

@test "build_review_specs emits one line per survivor" {
  local s1=$'o\tr1\t1\th\tb1\t\tu1' s2=$'o\tr2\t2\th\tb2\tc2\tu2'
  run build_review_specs "$s1" "$s2"
  [ "${#lines[@]}" -eq 2 ]
}
