-module(kirari_test_ffi).
-export([create_test_tarball/0]).

%% 테스트용: "hello.txt" 파일 하나가 든 .tar.gz를 메모리에 반환
create_test_tarball() ->
    Content = <<"hello from kir test\n">>,
    Rand = integer_to_list(erlang:unique_integer([positive])),
    TmpDir = filename:join(filename:basedir(user_cache, "kir_test"), "tar_" ++ Rand),
    ok = filelib:ensure_dir(filename:join(TmpDir, "x")),
    %% 임시 파일에 내용 쓰기
    TmpContent = filename:join(TmpDir, "hello.txt"),
    ok = file:write_file(TmpContent, Content),
    %% tar.gz 생성 (상대 경로 사용)
    TmpTar = filename:join(TmpDir, "test.tar.gz"),
    ok = erl_tar:create(TmpTar, [{"hello.txt", TmpContent}], [compressed]),
    %% 읽고 정리
    {ok, Bin} = file:read_file(TmpTar),
    file:delete(TmpTar),
    file:delete(TmpContent),
    file:del_dir(TmpDir),
    Bin.
