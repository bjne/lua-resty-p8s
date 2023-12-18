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

=== TEST 1: default labels
--- http_config eval: $::http_config
--- config
    location /p8s {
        content_by_lua_block {
            local counter = p8s.counter("counter", "label1", "label2"):labels("default1")
            counter(1, "label2")
            p8s(false, true)
        }
    }
--- request
GET /p8s
--- response_body
# TYPE counter counter
counter{label1="default1",label2="label2"} 1

=== TEST 2: more default labels
--- http_config eval: $::http_config
--- config
    location /p8s {
        content_by_lua_block {
            local counter = p8s.counter("counter", "label1", "label2"):labels("default1", "default2")
            counter(1)
            p8s(false, true)
        }
    }
--- request
GET /p8s
--- response_body
# TYPE counter counter
counter{label1="default1",label2="default2"} 1

=== TEST 3: second label default
--- http_config eval: $::http_config
--- config
    location /p8s {
        content_by_lua_block {
            local counter = p8s.counter("counter", "label1", "label2"):labels(nil, "default2")
            counter(1, "label1")
            p8s(false, true)
        }
    }
--- request
GET /p8s
--- response_body
# TYPE counter counter
counter{label1="label1",label2="default2"} 1
