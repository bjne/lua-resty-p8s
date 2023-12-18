# vim:set ts=4 sw=4 et fdm=marker:
BEGIN {
    $ENV{TEST_NGINX_REUSE_PORT} = 1;
}

use Test::Nginx::Socket 'no_plan';

master_on();
workers(4);

our $http_config = <<'_EOC_';
    lua_shared_dict resty_p8s 10M;
    lua_package_path "$prefix/../../lib/?.lua;;";

    init_by_lua_block {
        p8s = require "resty.p8s"
    }

    init_worker_by_lua_block {
        counter = p8s.counter("counter"):help("Help Me!")
        counter(10)
        p8s.sync()
    }
_EOC_

no_long_string();
run_tests();

__DATA__

=== TEST 1: reset local
--- http_config eval: $::http_config
--- config
    location /p8s {
        content_by_lua_block {
            p8s(false, true)
        }
    }
--- request
GET /p8s
--- response_body eval
qr/^# HELP counter Help Me!
# TYPE counter counter
counter 40 \d+$/
