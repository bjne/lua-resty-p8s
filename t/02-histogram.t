# vim:set ts=4 sw=4 et fdm=marker:

#BEGIN {
#    $ENV{TEST_NGINX_USE_HUP} = 1;
#}

use Test::Nginx::Socket 'no_plan';


our $http_config = <<'_EOC_';
    lua_shared_dict resty_p8s 10M;
    lua_package_path "$prefix/../../lib/?.lua;;";


    init_by_lua_block {
        p8s = require "resty.p8s"
    }
_EOC_

no_long_string();
run_tests();

__DATA__

=== TEST 1: histogram initialization
--- http_config eval: $::http_config
--- config
    location /p8s {
        content_by_lua_block {
            local histogram = p8s.histogram("histogram")
            p8s(false, true)
        }
    }
--- request
GET /p8s
--- response_body
# TYPE histogram histogram
histogram_bucket{le="0.05"} 0
histogram_bucket{le="0.1"} 0
histogram_bucket{le="0.2"} 0
histogram_bucket{le="0.5"} 0
histogram_bucket{le="1"} 0
histogram_bucket{le="+Inf"} 0
histogram_count 0
histogram_sum 0

=== TEST 2: histogram increment
--- http_config eval: $::http_config
--- config
    location /p8s {
        content_by_lua_block {
            local histogram = p8s.histogram("histogram")
            histogram(0.25)
            p8s(false, true)
        }
    }
--- request
GET /p8s
--- response_body
# TYPE histogram histogram
histogram_bucket{le="0.05"} 0
histogram_bucket{le="0.1"} 0
histogram_bucket{le="0.2"} 0
histogram_bucket{le="0.5"} 1
histogram_bucket{le="1"} 1
histogram_bucket{le="+Inf"} 1
histogram_count 1
histogram_sum 0.25

=== TEST 3: histogram null label
--- http_config eval: $::http_config
--- config
    location /p8s {
        content_by_lua_block {
            local histogram = p8s.histogram("label_histogram", "lbl1", "lbl2")
            histogram(0.25)
            p8s(false, true)
        }
    }
--- request
GET /p8s
--- response_body
# TYPE label_histogram histogram
label_histogram_bucket{lbl1="null",lbl2="null",le="0.05"} 0
label_histogram_bucket{lbl1="null",lbl2="null",le="0.1"} 0
label_histogram_bucket{lbl1="null",lbl2="null",le="0.2"} 0
label_histogram_bucket{lbl1="null",lbl2="null",le="0.5"} 1
label_histogram_bucket{lbl1="null",lbl2="null",le="1"} 1
label_histogram_bucket{lbl1="null",lbl2="null",le="+Inf"} 1
label_histogram_count{lbl1="null",lbl2="null"} 1
label_histogram_sum{lbl1="null",lbl2="null"} 0.25


=== TEST 4: histogram label
--- http_config eval: $::http_config
--- config
    location /p8s {
        content_by_lua_block {
            local histogram = p8s.histogram("label_histogram", "lbl1", "lbl2")
            histogram(0.25, "foo","bar")
            p8s(false, true)
        }
    }
--- request
GET /p8s
--- response_body
# TYPE label_histogram histogram
label_histogram_bucket{lbl1="foo",lbl2="bar",le="0.05"} 0
label_histogram_bucket{lbl1="foo",lbl2="bar",le="0.1"} 0
label_histogram_bucket{lbl1="foo",lbl2="bar",le="0.2"} 0
label_histogram_bucket{lbl1="foo",lbl2="bar",le="0.5"} 1
label_histogram_bucket{lbl1="foo",lbl2="bar",le="1"} 1
label_histogram_bucket{lbl1="foo",lbl2="bar",le="+Inf"} 1
label_histogram_count{lbl1="foo",lbl2="bar"} 1
label_histogram_sum{lbl1="foo",lbl2="bar"} 0.25

=== TEST 5: histogram incr label
--- http_config eval: $::http_config
--- config
    location /p8s {
        content_by_lua_block {
            local histogram = p8s.histogram("label_histogram", "lbl1", "lbl2")
            histogram(0.51, "foo","bar")
            p8s(false, true)
        }
    }
--- request
GET /p8s
--- response_body
# TYPE label_histogram histogram
label_histogram_bucket{lbl1="foo",lbl2="bar",le="0.05"} 0
label_histogram_bucket{lbl1="foo",lbl2="bar",le="0.1"} 0
label_histogram_bucket{lbl1="foo",lbl2="bar",le="0.2"} 0
label_histogram_bucket{lbl1="foo",lbl2="bar",le="0.5"} 0
label_histogram_bucket{lbl1="foo",lbl2="bar",le="1"} 1
label_histogram_bucket{lbl1="foo",lbl2="bar",le="+Inf"} 1
label_histogram_count{lbl1="foo",lbl2="bar"} 1
label_histogram_sum{lbl1="foo",lbl2="bar"} 0.51
