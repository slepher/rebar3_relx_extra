-module(rebar3_prv_clusup).

-export([init/1, do/1, format_error/1]).

-define(PROVIDER, clusup).
-define(DEPS, []).
%% -define(DEPS, [release]).

%% ===================================================================
%% Public API
%% ===================================================================
-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
    Provider = providers:create([{name, ?PROVIDER},
                                 {module, ?MODULE},
                                 {bare, true},
                                 {deps, ?DEPS},
                                 {example, "rebar3 relup"},
                                 {short_desc, "Create relup of releases."},
                                 {desc, "Create relup of releases."},
                                 {opts, relx:opt_spec_list()}]),
    State1 = rebar_state:add_provider(State, Provider),
    {ok, State1}.

-spec do(rebar_state:t()) -> {ok, rebar_state:t()} | {error, string()}.
do(State) ->
    case rlx_ext_lib:update_rlx(State) of
        {ok, State1} ->
            case rebar_relx:do(rlx_prv_clusup, "clusup", ?PROVIDER, State1) of
                {ok, _} ->
                    {ok, State1};
                {error, Reason} ->
                    {error, Reason}
              end;
        {error, Reason} ->
            {error, Reason}
    end.

-spec format_error(any()) ->  iolist().
format_error(Reason) ->
    io_lib:format("~p", [Reason]).
    
