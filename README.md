rebar3_relx_extra
=====

A rebar plugin

Build
-----

    $ rebar3 compile

Use
---

Add the plugin to your rebar config:

    {plugins, [
        { rebar3_relx_extra, ".*", {git, "git@host:user/rebar3_relx_extra.git", {tag, "0.1.0"}}}
    ]}.

Then just call your plugin directly in an existing application:


    $ rebar3 rebar3_relx_extra
    ===> Fetching rebar3_relx_extra
    ===> Compiling rebar3_relx_extra
    <Plugin Output>
