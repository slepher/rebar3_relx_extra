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
-module(relx_prv_clustar).

-export([do/2,
         format_error/1]).

-export([sub_release_files/3]).

%%============================================================================
%% API
%%============================================================================
do(Cluster, State) ->
    RelxState = relx_ext_state:rlx_state(State),
    ClusName = relx_ext_cluster:name(Cluster),
    BaseOutputDir = rlx_state:base_output_dir(RelxState),
    OutputDir = filename:join(BaseOutputDir, ClusName),
    Releases = relx_ext_cluster:solved_releases(Cluster),
    make_tar(State, Cluster, Releases, OutputDir).

make_tar(State, Cluster, SubReleases, OutputDir) ->
    Name = relx_ext_cluster:name(Cluster),
    Vsn = relx_ext_cluster:vsn(Cluster),
    TarFile = filename:join(OutputDir, atom_to_list(Name) ++ "_" ++ Vsn ++ ".tar.gz"),
    Files = tar_files(State, Cluster, SubReleases, OutputDir),
    ok = erl_tar:create(TarFile, Files, [dereference,compressed]),
    rebar_api:info("tarball ~s successfully created!~n", [TarFile]),
    {ok, State}.
    
tar_files(StateExt, Cluster, SubReleases, OutputDir) ->
    State = relx_ext_state:rlx_state(StateExt),
    Name = relx_ext_cluster:name(Cluster),
    Vsn = relx_ext_cluster:vsn(Cluster),
    Release = relx_ext_cluster:solved_clus_release(Cluster),
    Applications = rlx_release:applications(Release),
    ErtsVsn = rlx_release:erts(Release),
    Paths = paths(State, OutputDir),
    Applications1 = simplize_applications(Applications),
    ApplicationsFiles = 
        lists:foldl(
          fun({AppName, AppVsn}, Acc) ->
                  {ok, ApplicationFiles} = 
                      relx_ext_lib:application_files(
                        AppName, AppVsn, Paths, [{dirs, [include | maybe_src_dirs(State)]}, {output_dir, OutputDir}]),
                  ApplicationFiles ++ Acc
          end, [], Applications1),
    SubReleaseFiles = 
        lists:foldl(
          fun(SubRelease, Acc) ->
                  sub_release_files(SubRelease, State, OutputDir) ++ Acc
          end, [], SubReleases),
    BinFiles = cluster_files(OutputDir, Name, Vsn),
    OverlayVars = rlx_overlay:generate_overlay_vars(State, Release),
    OverlayFiles = overlay_files(OverlayVars, relx_ext_state:overlay(StateExt), OutputDir),
    ErtsFiles = erts_files(ErtsVsn, State),
    ApplicationsFiles ++ SubReleaseFiles ++ OverlayFiles ++ ErtsFiles ++ BinFiles.

paths(State, OutputDir) ->
    SystemLibs = rlx_state:system_libs(State),
    Paths = relx_ext_lib:path([{path, [filename:join([OutputDir, "lib", "*", "ebin"])]}]),
        case SystemLibs of
            true ->
                Paths;
            false ->
                lists:filter(
                  fun(Path) ->
                          not lists:prefix(code:lib_dir(), Path)
                  end, Paths)
        end.

erts_files(ErtsVsn, State) ->
    case erts_prefix(State) of
        false ->
            [];
        Prefix ->
            ErtsDir = filename:join([Prefix]),
            FromDir = filename:join([ErtsDir, "erts-" ++ ErtsVsn, "bin"]),
	    ToDir = filename:join("erts-" ++ ErtsVsn, "bin"),
            [{ToDir, FromDir}]
    end.

erts_prefix(State) ->
    case rlx_state:include_erts(State) of
        true ->
            code:root_dir();
        false ->
            false;
        undefined -> 
            false;
        Prefix ->
            Prefix
    end.

cluster_files(OutputDir, RelName, RelVsn) ->
    BinFile = atom_to_list(RelName),
    ClusFile = atom_to_list(RelName) ++ ".clus",
    [{filename:join(["bin", BinFile]), filename:join([OutputDir, "bin", BinFile])}, 
     {filename:join(["releases", RelVsn, ClusFile]),  filename:join([OutputDir, "releases", RelVsn, ClusFile])}].

sub_release_files(Release, State, OutputDir) ->
    RelName = rlx_release:name(Release),
    RelVsn = rlx_release:vsn(Release),
    OverlayVars = rlx_overlay:generate_overlay_vars(State, Release),
    SubReleaseDir = filename:join(["clients", RelName]),
    SubOutputDir = filename:join([OutputDir, "clients", RelName]),
    OverlayFiles = sub_overlay_files(OverlayVars, rlx_state:overlay(State), SubOutputDir, SubReleaseDir),
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
         File = rlx_overlay:render_string(OverlayVars, To),
         {ec_cnv:to_list(File), ec_cnv:to_list(filename:join(OutputDir, File))}
     end || O <- Overlay, filter(O)].

sub_overlay_files(_, undefined, _, _) ->
    [];
sub_overlay_files(OverlayVars, Overlay, OutputDir, SubReleaseDir) ->
    [begin
         To = to(O),
         File = rlx_overlay:render_string(OverlayVars, To),
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
    case include_src_or_default(State) of
        false -> [];
        true -> [src]
    end.

%% when running `tar' the default is to exclude src
include_src_or_default(State) ->
    case rlx_state:include_src(State) of
        undefined ->
            false;
        IncludeSrc ->
            IncludeSrc
    end.

simplize_applications(Applications) ->
    lists:map(
      fun(#{name := AppName, vsn := AppVsn}) ->
              {AppName, AppVsn}
      end, Applications).
