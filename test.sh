#!/usr/bin/env bash

cpan Test::Nginx Test::Nginx::Socket

export PATH=/usr/local/openresty/nginx/sbin:$PATH

exec prove -r t/
