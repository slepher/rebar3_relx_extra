-module(rebar_compiler_dag_lib).

-export([find_source_files/4]).
-export([init_dag/7]).

-type extension() :: string().
-type out_mappings() :: [{extension(), file:filename()}].

-callback context(rebar_app_info:t()) -> #{src_dirs     => [file:dirname()],
                                           include_dirs => [file:dirname()],
                                           src_ext      => extension(),
                                           out_mappings => out_mappings()}.
-callback needed_files(digraph:graph(), [file:filename()], out_mappings(),
                       rebar_app_info:t()) ->
    {{[file:filename()], term()}, % ErlFirstFiles (erl_opts global priority)
     {[file:filename()] | % [Sequential]
      {[file:filename()], [file:filename()]}, % {Sequential, Parallel}
      term()}}.
-callback dependencies(file:filename(), file:dirname(), [file:dirname()]) -> [file:filename()].
-callback compile(file:filename(), out_mappings(), rebar:rebar_dict(), list()) ->
    ok | {ok, [string()]} | {ok, [string()], [string()]}.
-callback clean([file:filename()], rebar_app_info:t()) -> _.

-define(DAG_VSN, 2).
-define(DAG_ROOT, "source").
-define(DAG_EXT, ".dag").
-type dag_v() :: {digraph:vertex(), term()} | 'false'.
-type dag_e() :: {digraph:vertex(), digraph:vertex()}.
-type dag() :: {list(dag_v()), list(dag_e()), list(string())}.
-record(dag, {vsn = ?DAG_VSN :: pos_integer(),
              info = {[], [], []} :: dag()}).

-define(RE_PREFIX, "^(?!\\._)").

%% private functions

find_source_files(BaseDir, SrcExt, SrcDirs, Opts) ->
    SourceExtRe = "^(?!\\._).*\\" ++ SrcExt ++ [$$],
    lists:flatmap(fun(SrcDir) ->
                      Recursive = rebar_dir:recursive(Opts, SrcDir),
                      rebar_utils:find_files_in_dirs([filename:join(BaseDir, SrcDir)], SourceExtRe, Recursive)
                  end, SrcDirs).

%% @private generate the name for the DAG based on the compiler module and
%% a custom label, both of which are used to prevent various compiler runs
%% from clobbering each other. The label `undefined' is kept for a default
%% run of the compiler, to keep in line with previous versions of the file.
dag_file(CompilerMod, Dir, undefined) ->
    filename:join([rebar_dir:local_cache_dir(Dir), CompilerMod,
                   ?DAG_ROOT ++ ?DAG_EXT]);
dag_file(CompilerMod, Dir, Label) ->
    filename:join([rebar_dir:local_cache_dir(Dir), CompilerMod,
                   ?DAG_ROOT ++ "_" ++ Label ++ ?DAG_EXT]).

%% private graph functions

%% Get dependency graph of given Erls files and their dependencies (header files,
%% parse transforms, behaviours etc.) located in their directories or given
%% InclDirs. Note that last modification times stored in vertices already respect
%% dependencies induced by given graph G.
init_dag(Compiler, InclDirs, SrcDirs, Erls, Dir, EbinDir, Label) ->
    G = digraph:new([acyclic]),
    try restore_dag(Compiler, G, InclDirs, Dir, Label)
    catch
        _:_ ->
            rebar_api:warn("Failed to restore ~ts file. Discarding it.~n", [dag_file(Compiler, Dir, Label)]),
            file:delete(dag_file(Compiler, Dir, Label))
    end,
    Dirs = lists:usort(InclDirs ++ SrcDirs),
    %% A source file may have been renamed or deleted. Remove it from the graph
    %% and remove any beam file for that source if it exists.
    Modified = maybe_rm_beams_and_edges(G, EbinDir, Erls),
    Modified1 = lists:foldl(update_dag_fun(G, Compiler, Dirs), Modified, Erls),
    if Modified1 -> store_dag(Compiler, G, InclDirs, Dir, Label);
       not Modified1 -> ok
    end,
    G.

maybe_rm_beams_and_edges(G, Dir, Files) ->
    Vertices = digraph:vertices(G),
    case lists:filter(fun(File) ->
                              case filename:extension(File) =:= ".erl" of
                                  true ->
                                      maybe_rm_beam_and_edge(G, Dir, File);
                                  false ->
                                      false
                              end
                      end, lists:sort(Vertices) -- lists:sort(Files)) of
        [] ->
            false;
        _ ->
            true
    end.

maybe_rm_beam_and_edge(G, OutDir, Source) ->
    %% This is NOT a double check it is the only check that the source file is actually gone
    case filelib:is_regular(Source) of
        true ->
            %% Actually exists, don't delete
            false;
        false ->
            Target = target_base(OutDir, Source) ++ ".beam",
            rebar_api:debug("Source ~ts is gone, deleting previous beam file if it exists ~ts", [Source, Target]),
            file:delete(Target),
            digraph:del_vertex(G, Source),
            true
    end.


target_base(OutDir, Source) ->
    filename:join(OutDir, filename:basename(Source, ".erl")).

restore_dag(Compiler, G, InclDirs, Dir, Label) ->
    case file:read_file(dag_file(Compiler, Dir, Label)) of
        {ok, Data} ->
            % Since externally passed InclDirs can influence dependency graph (see
            % modify_dag), we have to check here that they didn't change.
            #dag{vsn=?DAG_VSN, info={Vs, Es, InclDirs}} =
                binary_to_term(Data),
            lists:foreach(
              fun({V, LastUpdated}) ->
                      digraph:add_vertex(G, V, LastUpdated)
              end, Vs),
            lists:foreach(
              fun({_, V1, V2, _}) ->
                      digraph:add_edge(G, V1, V2)
              end, Es);
        {error, _} ->
            ok
    end.

store_dag(Compiler, G, InclDirs, Dir, Label) ->
    Vs = lists:map(fun(V) -> digraph:vertex(G, V) end, digraph:vertices(G)),
    Es = lists:map(fun(E) -> digraph:edge(G, E) end, digraph:edges(G)),
    File = dag_file(Compiler, Dir, Label),
    ok = filelib:ensure_dir(File),
    Data = term_to_binary(#dag{info={Vs, Es, InclDirs}}, [{compressed, 2}]),
    file:write_file(File, Data).

update_dag(G, Compiler, Dirs, Source) ->
    case digraph:vertex(G, Source) of
        {_, LastUpdated} ->
            case filelib:last_modified(Source) of
                0 ->
                    %% The file doesn't exist anymore,
                    %% erase it from the graph.
                    %% All the edges will be erased automatically.
                    digraph:del_vertex(G, Source),
                    modified;
                LastModified when LastUpdated < LastModified ->
                    modify_dag(G, Compiler, Source, LastModified, filename:dirname(Source), Dirs);
                _ ->
                    Modified = lists:foldl(
                        update_dag_fun(G, Compiler, Dirs),
                        false, digraph:out_neighbours(G, Source)),
                    MaxModified = update_max_modified_deps(G, Source),
                    case Modified orelse MaxModified > LastUpdated of
                        true -> modified;
                        false -> unmodified
                    end
            end;
        false ->
            modify_dag(G, Compiler, Source, filelib:last_modified(Source), filename:dirname(Source), Dirs)
    end.

modify_dag(G, Compiler, Source, LastModified, SourceDir, Dirs) ->
    AbsIncls = Compiler:dependencies(Source, SourceDir, Dirs),
    digraph:add_vertex(G, Source, LastModified),
    digraph:del_edges(G, digraph:out_edges(G, Source)),
    lists:foreach(
      fun(Incl) ->
              update_dag(G, Compiler, Dirs, Incl),
              digraph:add_edge(G, Source, Incl)
      end, AbsIncls),
    modified.

update_dag_fun(G, Compiler, Dirs) ->
    fun(Erl, Modified) ->
        case update_dag(G, Compiler, Dirs, Erl) of
            modified -> true;
            unmodified -> Modified
        end
    end.

update_max_modified_deps(G, Source) ->
    MaxModified =
        lists:foldl(fun(File, Acc) ->
                            case digraph:vertex(G, File) of
                                {_, MaxModified} when MaxModified > Acc ->
                                    MaxModified;
                                _ ->
                                    Acc
                            end
                    end, 0, [Source | digraph:out_neighbours(G, Source)]),
    digraph:add_vertex(G, Source, MaxModified),
    MaxModified.
