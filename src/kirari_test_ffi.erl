-module(kirari_test_ffi).
-export([create_test_tarball/0, create_hex_test_tarball/0, create_npm_test_tarball/0]).

%% 기본 테스트용: "hello.txt" 파일 하나가 든 .tar.gz
create_test_tarball() ->
    Content = <<"hello from kir test\n">>,
    Rand = integer_to_list(erlang:unique_integer([positive])),
    TmpDir = filename:join(filename:basedir(user_cache, "kir_test"), "tar_" ++ Rand),
    ok = filelib:ensure_dir(filename:join(TmpDir, "x")),
    TmpContent = filename:join(TmpDir, "hello.txt"),
    ok = file:write_file(TmpContent, Content),
    TmpTar = filename:join(TmpDir, "test.tar.gz"),
    ok = erl_tar:create(TmpTar, [{"hello.txt", TmpContent}], [compressed]),
    {ok, Bin} = file:read_file(TmpTar),
    file:delete(TmpTar),
    file:delete(TmpContent),
    file:del_dir(TmpDir),
    Bin.

%% Hex 형식 tarball: 비압축 외부 tar(VERSION, contents.tar.gz)
create_hex_test_tarball() ->
    Rand = integer_to_list(erlang:unique_integer([positive])),
    TmpDir = filename:join(filename:basedir(user_cache, "kir_test"), "hex_" ++ Rand),
    ok = filelib:ensure_dir(filename:join(TmpDir, "x")),
    %% 1. 내부 contents.tar.gz 생성
    SrcFile = filename:join(TmpDir, "src_hello.gleam"),
    ok = file:write_file(SrcFile, <<"pub fn main() { Nil }\n">>),
    ContentsTarGz = filename:join(TmpDir, "contents.tar.gz"),
    ok = erl_tar:create(ContentsTarGz, [{"src/hello.gleam", SrcFile}], [compressed]),
    %% 2. VERSION 파일
    VersionFile = filename:join(TmpDir, "VERSION"),
    ok = file:write_file(VersionFile, <<"3">>),
    %% 3. 외부 비압축 tar 생성
    OuterTar = filename:join(TmpDir, "outer.tar"),
    ok = erl_tar:create(OuterTar, [
        {"VERSION", VersionFile},
        {"contents.tar.gz", ContentsTarGz}
    ], []),
    {ok, Bin} = file:read_file(OuterTar),
    %% 정리
    file:delete(OuterTar),
    file:delete(ContentsTarGz),
    file:delete(VersionFile),
    file:delete(SrcFile),
    file:del_dir(TmpDir),
    Bin.

%% npm 형식 tarball: gzip tar with package/ prefix
create_npm_test_tarball() ->
    Rand = integer_to_list(erlang:unique_integer([positive])),
    TmpDir = filename:join(filename:basedir(user_cache, "kir_test"), "npm_" ++ Rand),
    ok = filelib:ensure_dir(filename:join(TmpDir, "x")),
    IndexFile = filename:join(TmpDir, "index.js"),
    ok = file:write_file(IndexFile, <<"module.exports = {};\n">>),
    PkgJson = filename:join(TmpDir, "package.json"),
    ok = file:write_file(PkgJson, <<"{\"name\":\"test\",\"version\":\"1.0.0\"}\n">>),
    TmpTar = filename:join(TmpDir, "npm.tgz"),
    ok = erl_tar:create(TmpTar, [
        {"package/index.js", IndexFile},
        {"package/package.json", PkgJson}
    ], [compressed]),
    {ok, Bin} = file:read_file(TmpTar),
    file:delete(TmpTar),
    file:delete(IndexFile),
    file:delete(PkgJson),
    file:del_dir(TmpDir),
    Bin.
