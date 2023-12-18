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

=== TEST 1: counter initialization
--- http_config eval: $::http_config
--- config
    location /p8s {
        content_by_lua_block {
            local counter = p8s.counter("counter")
            p8s(false, true)
        }
    }
--- request
GET /p8s
--- response_body
# TYPE counter counter
counter 0 0

=== TEST 2: counter increment
--- http_config eval: $::http_config
--- config
    location /p8s {
        content_by_lua_block {
            local counter = p8s.counter("counter")
            counter()
            p8s(false, true)
        }
    }
--- request
GET /p8s
--- response_body eval
qr/^# TYPE counter counter
counter 1 \d+$/

=== TEST 3: counter null label
--- http_config eval: $::http_config
--- config
    location /p8s {
        content_by_lua_block {
            local counter = p8s.counter("label_counter", "lbl1", "lbl2")
            counter()
            p8s(false, true)
        }
    }
--- request
GET /p8s
--- response_body
# TYPE label_counter counter
label_counter{lbl1="null",lbl2="null"} 1

=== TEST 4: counter label
--- http_config eval: $::http_config
--- config
    location /p8s {
        content_by_lua_block {
            local counter = p8s.counter("label_counter", "lbl1", "lbl2")
            counter(1, "foo","bar")
            p8s(false, true)
        }
    }
--- request
GET /p8s
--- response_body
# TYPE label_counter counter
label_counter{lbl1="foo",lbl2="bar"} 1

=== TEST 5: counter incr label
--- http_config eval: $::http_config
--- config
    location /p8s {
        content_by_lua_block {
            local counter = p8s.counter("label_counter", "lbl1", "lbl2")
            counter(3, "foo","bar")
            p8s(false, true)
        }
    }
--- request
GET /p8s
--- response_body
# TYPE label_counter counter
label_counter{lbl1="foo",lbl2="bar"} 3
