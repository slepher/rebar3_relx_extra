%%%-------------------------------------------------------------------
%%% @author Chen Slepher <slepheric@gmail.com>
%%% @copyright (C) 2020, Chen Slepher
%%% @doc
%%%
%%% @end
%%% Created : 16 Jan 2020 by Chen Slepher <slepheric@gmail.com>
%%%-------------------------------------------------------------------
-module(rlx_ext_release_lib).

%% API
-export([realize_sub_releases/3]).
%%%===================================================================
%%% API
%%%===================================================================
realize_sub_releases(Release, SubReleases, State) ->
    Config = rlx_release:config(Release),
    InclApps = incl_apps(Config),
    DepGraph = create_dep_graph(State),
    realize_sub_releases_1(SubReleases, DepGraph, InclApps, State).

%%--------------------------------------------------------------------
%% @doc
%% @spec
%% @end
%%--------------------------------------------------------------------

%%%===================================================================
%%% Internal functions
%%%===================================================================
realize_sub_releases_1([{SubReleaseName, SubReleaseVsn}|T], DepGraph, InclApps, State) ->
    case realized_release(State, DepGraph, InclApps, SubReleaseName, SubReleaseVsn) of
        {ok, RealizedSubRelease} ->
            State1 = rlx_state:add_realized_release(State, RealizedSubRelease),
            realize_sub_releases_1(T, DepGraph, InclApps, State1);
        {error, Reason} ->
            {error, Reason}
    end;
realize_sub_releases_1([], _DepGraph, _InclApps, State) ->
    {ok, State}.

realized_release(State, DepGraph, InclApps, Name, Vsn) ->
    Release = rlx_state:get_configured_release(State, Name, Vsn),
    {ok, Release1} = rlx_release:goals(Release, InclApps),
    Goals = rlx_release:goals(Release1),
    case Goals of
        [] ->
            {error, {Name, no_goals_specified}};
        _ ->
            case rlx_depsolver:solve(DepGraph, Goals) of
                {ok, Pkgs} ->
                    rlx_release:realize(Release1, Pkgs, rlx_state:available_apps(State));
                {error, Error} ->
                    {error, {Name, failed_solve, Error}}
            end
    end.

incl_apps(Config) ->
    case proplists:get_value(incl_apps, Config) of
        undefined ->
            [];
        Apps ->
            Apps
    end.

create_dep_graph(State) ->
    Apps = rlx_state:available_apps(State),
    Graph0 = rlx_depsolver:new_graph(),
    lists:foldl(fun(App, Graph1) ->
                        AppName = rlx_app_info:name(App),
                        AppVsn = rlx_app_info:vsn(App),
                        Deps = rlx_app_info:active_deps(App) ++
                            rlx_app_info:library_deps(App),
                        rlx_depsolver:add_package_version(Graph1,
                                                          AppName,
                                                          AppVsn,
                                                          Deps)
                end, Graph0, Apps).
