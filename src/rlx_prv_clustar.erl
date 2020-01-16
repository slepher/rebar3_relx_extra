%% -*- erlang-indent-level: 4; indent-tabs-mode: nil; fill-column: 80 -*-
%%% Copyright 2014 Erlware, LLC. All Rights Reserved.
%%%
%%% This file is provided to you under the Apache License,
%%% Version 2.0 (the "License"); you may not use this file
%%% except in compliance with the License.  You may obtain
%%% a copy of the License at
%%%
%%%   http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing,
%%% software distributed under the License is distributed on an
%%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%%% KIND, either express or implied.  See the License for the
%%% specific language governing permissions and limitations
%%% under the License.
%%%---------------------------------------------------------------------------
%%% @author Tristan Sloughter <t@crashfast.com>
%%% @copyright (C) 2014 Erlware, LLC.
%%%
%%% @doc Given a complete built release this provider assembles that release
%%% into a release directory.
-module(rlx_prv_clustar).

-behaviour(provider).

-export([init/1,
         do/1,
         format_error/1]).

-define(PROVIDER, clustar).
-define(DEPS, [resolve_release]).

-include_lib("relx/include/relx.hrl").

%%============================================================================
%% API
%%============================================================================

-spec init(rlx_state:t()) -> {ok, rlx_state:t()}.
init(State) ->
    State1 = rlx_state:add_provider(State, providers:create([{name, ?PROVIDER},
                                                             {module, ?MODULE},
                                                             {deps, ?DEPS}])),

    {ok, State1}.

-spec do(rlx_state:t()) -> {ok, rlx_state:t()} | relx:error().
do(State) ->
    {RelName, RelVsn} = rlx_state:default_configured_release(State),
    Release = rlx_state:get_realized_release(State, RelName, RelVsn),
    OutputDir = rlx_state:output_dir(State),
    Config = rlx_release:config(Release),
    SubReleases = proplists:get_value(ext, Config),
    case rlx_ext_release_lib:realize_sub_releases(Release, SubReleases, State) of
        {ok, State1} ->
            make_tar(State1, Release, SubReleases, OutputDir);
        {error, Reason} ->
            {error, Reason}
    end.

make_tar(State, Release, SubReleases, OutputDir) ->
    Name = atom_to_list(rlx_release:name(Release)),
    Vsn = rlx_release:vsn(Release),
    ErtsVersion = rlx_release:erts(Release),
    Opts = [{path, [filename:join([OutputDir, "lib", "*", "ebin"])]},
            {dirs, [include | maybe_src_dirs(State)]},
            {outdir, OutputDir} |
            case rlx_state:get(State, include_erts, true) of
                true ->
                    Prefix = code:root_dir(),
                    ErtsDir = filename:join([Prefix]),
                    [{erts, ErtsDir}];
                false ->
                    [];
                Prefix ->
                    ErtsDir = filename:join([Prefix]),
                    [{erts, ErtsDir}]
            end],
    case systools:make_tar(filename:join([OutputDir, "releases", Vsn, Name]),
                           Opts) of
        ok ->
            TempDir = ec_file:insecure_mkdtemp(),
            try
                update_tar(State, SubReleases, TempDir, OutputDir, Name, Vsn, ErtsVersion)
            catch
                E:R:Stacktrace ->
                    io:format("trace is ~p~n", [Stacktrace]),
                    ec_file:remove(TempDir, [recursive]),
                    ?RLX_ERROR({tar_generation_error, E, R})
            end;
        {ok, Module, Warnings} ->
            ?RLX_ERROR({tar_generation_warn, Module, Warnings});
        error ->
            ?RLX_ERROR({tar_unknown_generation_error, Name, Vsn});
        {error, Module, Errors} ->
            ?RLX_ERROR({tar_generation_error, Module, Errors})
    end.

update_tar(State, SubReleases, TempDir, OutputDir, Name, Vsn, ErtsVersion) ->
    IncludeErts = rlx_state:get(State, include_erts, true),
    SystemLibs = rlx_state:get(State, system_libs, true),
    {RelName, RelVsn} = rlx_state:default_configured_release(State),
    Release = rlx_state:get_realized_release(State, RelName, RelVsn),
    TarFile = filename:join(OutputDir, Name++"-"++Vsn++".tar.gz"),
    file:rename(filename:join(OutputDir, Name++".tar.gz"), TarFile),
    erl_tar:extract(TarFile, [{cwd, TempDir}, compressed]),
    BinFiles = cluster_files(OutputDir, Vsn),
    OverlayVars = rlx_prv_overlay:generate_overlay_vars(State, Release),
    OverlayFiles = overlay_files(OverlayVars, rlx_state:get(State, overlay, undefined), OutputDir),
    SubReleaseFiles = 
        lists:foldl(
          fun({SubReleaseName, SubReleaseVsn}, Acc) ->
                  State1 = rlx_ext_lib:sub_release_state(State, Release, SubReleaseName, SubReleaseVsn),
                  sub_release_files(State1, OutputDir) ++ Acc
          end, [], SubReleases),
    ok =
        erl_tar:create(TarFile,
                       case IncludeErts of
                           false ->
                               %% Remove system libs from tarball
                               case SystemLibs of
                                   false ->
                                       Libs = filelib:wildcard("*", filename:join(TempDir, "lib")),
                                       AllSystemLibs = filelib:wildcard("*", code:lib_dir()),
                                       [{filename:join("lib", LibDir), filename:join([TempDir, "lib", LibDir])} ||
                                           LibDir <- lists:subtract(Libs, AllSystemLibs)];
                                   _ ->
                                       [{"lib", filename:join(TempDir, "lib")}]
                               end;
                           _ ->
                               [{"lib", filename:join(TempDir, "lib")},
                                {"erts-"++ErtsVersion, filename:join(OutputDir, "erts-"++ErtsVersion)}]
                       end++OverlayFiles ++ SubReleaseFiles ++ BinFiles, [dereference,compressed]),
    ec_cmd_log:info(rlx_state:log(State), "tarball ~s successfully created!~n", [TarFile]),
    ec_file:remove(TempDir, [recursive]),
    {ok, State}.

cluster_files(OutputDir, RelVsn) ->
    [{"bin", filename:join([OutputDir, "bin"])}, 
     {"clus", filename:join([OutputDir, "clus"])}, 
     {"clusup", filename:join([OutputDir, "clusup"])},
     {filename:join(["releases", RelVsn]),  filename:join([OutputDir, "releases", RelVsn])}].

sub_release_files(State, OutputDir) ->
    {RelName, RelVsn} = rlx_state:default_configured_release(State),
    Release = rlx_state:get_realized_release(State, RelName, RelVsn),
    OverlayVars = rlx_prv_overlay:generate_overlay_vars(State, Release),
    SubReleaseDir = filename:join(["clients", RelName]),
    SubOutputDir = filename:join([OutputDir, "clients", RelName]),
    OverlayFiles = sub_overlay_files(OverlayVars, rlx_state:get(State, overlay, undefined), SubOutputDir, SubReleaseDir),
    ConfigFiles = sub_config_files(RelVsn, OutputDir, SubReleaseDir),
    [{filename:join([SubReleaseDir, "releases", RelVsn]), 
      filename:join([SubOutputDir, "releases", RelVsn])},
     {filename:join([SubReleaseDir, "releases", "start_erl.data"]),
      filename:join([SubOutputDir, "releases", "start_erl.data"])},
     {filename:join([SubReleaseDir, "releases", "RELEASES"]),
      filename:join([SubOutputDir, "releases", "RELEASES"])} |
     ConfigFiles ++ OverlayFiles].

format_error({tar_unknown_generation_error, Module, Vsn}) ->
    io_lib:format("Tarball generation error of ~s ~s",
                  [Module, Vsn]);
format_error({tar_generation_warn, Module, Warnings}) ->
    io_lib:format("Tarball generation warnings for ~p : ~p",
                  [Module, Warnings]);
format_error({tar_generation_error, Module, Errors}) ->
    io_lib:format("Tarball generation error for ~p reason ~p",
                  [Module, Errors]).

sub_config_files(Vsn, OutputDir, SubReleaseDir) ->
    VMArgs = {filename:join([SubReleaseDir, "releases", Vsn, "vm.args"]),
              filename:join([OutputDir, "releases", Vsn, "vm.args"])},
    VMArgsOrig = {filename:join([SubReleaseDir, "releases", Vsn, "vm.args.orig"]), 
                  filename:join([OutputDir, "releases", Vsn, "vm.args.orig"])},
    SysConfigOrig = {filename:join([SubReleaseDir, "releases", Vsn, "sys.config.orig"]), 
                     filename:join([OutputDir, "releases", Vsn, "sys.config.orig"])},
    [{NameInArchive, Filename} || {NameInArchive, Filename} <- [VMArgs, VMArgsOrig, SysConfigOrig], filelib:is_file(Filename)].

overlay_files(_, undefined, _) ->
    [];
overlay_files(OverlayVars, Overlay, OutputDir) ->
    [begin
         To = to(O),
         File = rlx_prv_overlay:render_string(OverlayVars, To),
         {ec_cnv:to_list(File), ec_cnv:to_list(filename:join(OutputDir, File))}
     end || O <- Overlay, filter(O)].

sub_overlay_files(_, undefined, _, _) ->
    [];
sub_overlay_files(OverlayVars, Overlay, OutputDir, SubReleaseDir) ->
    [begin
         To = to(O),
         File = rlx_prv_overlay:render_string(OverlayVars, To),
         {ec_cnv:to_list(filename:join(SubReleaseDir, File)), ec_cnv:to_list(filename:join(OutputDir, File))}
     end || O <- Overlay, filter(O)].

to({link, _, To}) ->
    To;
to({copy, _, To}) ->
    To;
to({mkdir, To}) ->
    To;
to({template, _, To}) ->
    To.

filter({_, _, "bin/"++_}) ->
    false;
filter({link, _, _}) ->
    true;
filter({copy, _, _}) ->
    true;
filter({mkdir, _}) ->
    true;
filter({template, _, _}) ->
    true;
filter(_) ->
    false.

maybe_src_dirs(State) ->
    case rlx_state:get(State, include_src, true) of
        false -> [];
        true -> [src]
    end.
