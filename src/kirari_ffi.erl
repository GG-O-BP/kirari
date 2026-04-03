-module(kirari_ffi).
-export([
    extract_tar/2,
    extract_tar_uncompressed/2,
    make_hardlink/2,
    atomic_rename/2,
    get_home_dir/0,
    halt/1,
    make_temp_dir/1,
    run_command/1
]).

%% tar/tgz 압축 해제
extract_tar(Data, Dest) when is_binary(Data), is_binary(Dest) ->
    DestStr = binary_to_list(Dest),
    case erl_tar:extract({binary, Data}, [compressed, {cwd, DestStr}]) of
        ok -> {ok, nil};
        {ok, _} -> {ok, nil};
        {error, Reason} -> {error, list_to_binary(lists:flatten(io_lib:format("~p", [Reason])))}
    end.

%% 비압축 tar 해제 (Hex 외부 tarball용)
extract_tar_uncompressed(Data, Dest) when is_binary(Data), is_binary(Dest) ->
    DestStr = binary_to_list(Dest),
    case erl_tar:extract({binary, Data}, [{cwd, DestStr}]) of
        ok -> {ok, nil};
        {ok, _} -> {ok, nil};
        {error, Reason} -> {error, list_to_binary(lists:flatten(io_lib:format("~p", [Reason])))}
    end.

%% 하드링크 생성
make_hardlink(Src, Dst) when is_binary(Src), is_binary(Dst) ->
    case file:make_link(binary_to_list(Src), binary_to_list(Dst)) of
        ok -> {ok, nil};
        {error, Reason} -> {error, atom_to_binary(Reason, utf8)}
    end.

%% 원자적 이름 변경
atomic_rename(Src, Dst) when is_binary(Src), is_binary(Dst) ->
    case file:rename(binary_to_list(Src), binary_to_list(Dst)) of
        ok -> {ok, nil};
        {error, Reason} -> {error, atom_to_binary(Reason, utf8)}
    end.

%% 홈 디렉토리
get_home_dir() ->
    case os:getenv("HOME") of
        false ->
            %% Windows fallback
            case os:getenv("USERPROFILE") of
                false -> {error, <<"HOME not set">>};
                Path -> {ok, list_to_binary(Path)}
            end;
        Path -> {ok, list_to_binary(Path)}
    end.

%% 프로세스 종료
halt(Code) when is_integer(Code) ->
    erlang:halt(Code).

%% 임시 디렉토리 생성
make_temp_dir(Base) when is_binary(Base) ->
    Rand = integer_to_list(erlang:unique_integer([positive])),
    Dir = binary_to_list(Base) ++ "/tmp-" ++ Rand,
    case file:make_dir(Dir) of
        ok -> {ok, list_to_binary(Dir)};
        {error, Reason} -> {error, atom_to_binary(Reason, utf8)}
    end.

%% 셸 명령어 실행 — 종료 코드와 출력 반환
run_command(Cmd) when is_binary(Cmd) ->
    CmdStr = binary_to_list(Cmd),
    Port = open_port({spawn, CmdStr}, [stream, exit_status, binary, stderr_to_stdout]),
    collect_port(Port, <<>>).

collect_port(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect_port(Port, <<Acc/binary, Data/binary>>);
        {Port, {exit_status, 0}} ->
            {ok, Acc};
        {Port, {exit_status, Code}} ->
            {error, {Code, Acc}}
    end.
