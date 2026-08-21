"""Tests for llmctl's parsers.

Everything here is a pure function over text that some other program printed,
which is exactly where a wrong number comes from. No test shells out, so the
suite runs on any machine with no engine installed.

    python3 -m unittest discover -s tests -v
"""
import importlib.util
import os
import unittest

# llmctl is a CLI with no .py extension, so it is loaded by path.
_PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "llmctl")
_spec = importlib.util.spec_from_loader(
    "llmctl", importlib.machinery.SourceFileLoader("llmctl", _PATH))
llmctl = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(llmctl)

GB = 1024 ** 3

# Real `vm_stat` output, trimmed to the keys that matter.
VM_STAT = """Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                              123456.
Pages active:                            456789.
Pages inactive:                          234567.
Pages speculative:                        12345.
Pages throttled:                              0.
Pages wired down:                        190000.
Pages purgeable:                          10000.
"Translation faults":                 987654321.
Pages copy-on-write:                    1234567.
Pages zero filled:                     12345678.
Pages reactivated:                       123456.
Pages purged:                             12345.
File-backed pages:                       800000.
Anonymous pages:                         700000.
Pages stored in compressor:               50000.
Pages occupied by compressor:             40000.
"""


class VMStat(unittest.TestCase):
    def test_used_excludes_file_backed_cache(self):
        """A model sitting in the page cache is reclaimable and must not count
        as used -- the whole point of the formula."""
        total = 64 * GB
        used, wired = llmctl.parse_vm_stat(VM_STAT, total)
        page = 16384
        expected = ((700000 - 10000) + 190000 + 40000) * page
        self.assertEqual(used, expected)
        self.assertEqual(wired, 190000 * page)
        # 800000 file-backed pages (12.2 GB) are NOT in the total.
        self.assertNotIn(800000 * page, (used,))

    def test_purgeable_larger_than_anonymous_does_not_underflow(self):
        text = ("Mach Virtual Memory Statistics: (page size of 16384 bytes)\n"
                "Anonymous pages: 100.\n"
                "Pages purgeable: 500.\n"
                "Pages wired down: 10.\n")
        used, wired = llmctl.parse_vm_stat(text, 64 * GB)
        self.assertEqual(used, 10 * 16384)      # app memory floors at 0, not negative
        self.assertEqual(wired, 10 * 16384)

    def test_used_is_clamped_to_total(self):
        text = ("Mach Virtual Memory Statistics: (page size of 16384 bytes)\n"
                "Anonymous pages: 99999999.\n")
        used, _ = llmctl.parse_vm_stat(text, 8 * GB)
        self.assertEqual(used, 8 * GB)

    def test_missing_page_size_falls_back_without_crashing(self):
        used, _ = llmctl.parse_vm_stat("Anonymous pages: 10.\n", 64 * GB)
        self.assertEqual(used, 10 * 16384)

    def test_quoted_keys_are_ignored_not_misparsed(self):
        """`vm_stat` quotes some keys; "Translation faults" is a counter, not a
        page count, and adding it would produce nonsense."""
        used, _ = llmctl.parse_vm_stat(VM_STAT, 64 * GB)
        self.assertLess(used, 64 * GB)


class PSRSS(unittest.TestCase):
    PS = ("  5242880 /Applications/Foo.app/Contents/MacOS/Foo\n"
          "  1048576 /Users/x/.lmstudio/extensions/backends/llama-server --port 1234\n"
          "  HEADER-JUNK not a number\n"
          "\n"
          "   524288 node /Users/x/.lmstudio/.internal/utils/node/index.js\n")

    def test_sums_only_matching_lines(self):
        tot, hits = llmctl.parse_ps_rss(self.PS, [".lmstudio/extensions"])
        self.assertEqual(tot, 1048576 * 1024)
        self.assertEqual(len(hits), 1)

    def test_multiple_patterns_count_a_line_once(self):
        tot, hits = llmctl.parse_ps_rss(
            self.PS, [".lmstudio/extensions", "llama-server"])
        self.assertEqual(tot, 1048576 * 1024)   # not double counted
        self.assertEqual(len(hits), 1)

    def test_non_numeric_and_blank_lines_are_skipped(self):
        tot, _ = llmctl.parse_ps_rss(self.PS, ["HEADER-JUNK"])
        self.assertEqual(tot, 0)


class OllamaPS(unittest.TestCase):
    OUT = ("NAME              ID              SIZE      PROCESSOR    UNTIL\n"
           "llama3.2:latest   a80c4f17acd5    4.0 GB    100% GPU     4 minutes from now\n"
           "qwen2.5:7b        845dbda0ea48    512 MB    100% GPU     3 minutes from now\n")

    def test_parses_gb_and_mb(self):
        models = llmctl.parse_ollama_ps(self.OUT)
        self.assertEqual([m["name"] for m in models],
                         ["llama3.2:latest", "qwen2.5:7b"])
        self.assertEqual(models[0]["bytes"], int(4.0 * GB))
        self.assertEqual(models[1]["bytes"], int(512 * GB / 1024))

    def test_header_only_output_yields_nothing(self):
        self.assertEqual(llmctl.parse_ollama_ps("NAME  ID  SIZE  PROCESSOR  UNTIL\n"), [])

    def test_empty_output_yields_nothing(self):
        self.assertEqual(llmctl.parse_ollama_ps(""), [])


class ClassifyServer(unittest.TestCase):
    def test_llama_server_by_comm(self):
        self.assertEqual(llmctl.classify_server("llama-server", "llama-server --port 8080"),
                         "llama.cpp")

    def test_llama_server_by_argv_when_comm_is_truncated(self):
        """Bundled servers show a truncated or absolute comm, so argv has to be
        matched too."""
        self.assertEqual(
            llmctl.classify_server("/Users/x/Library/Applic",
                                   "/Users/x/Library/Application Support/Jan/llama-server --port 0"),
            "llama.cpp")

    def test_mlx_lm_is_only_visible_as_a_module_name(self):
        self.assertEqual(
            llmctl.classify_server("Python", "python3 -m mlx_lm.server --port 8131"),
            "mlx-lm")

    def test_mlx_vlm_counts_too(self):
        self.assertEqual(
            llmctl.classify_server("Python", "python3 -m mlx_vlm.server --port 8143"),
            "mlx-lm")

    def test_localai_matches_on_comm_suffix_only(self):
        self.assertEqual(llmctl.classify_server("/opt/homebrew/bin/local-ai",
                                                "local-ai run --address :8080"),
                         "LocalAI")

    def test_unrelated_process_is_none(self):
        self.assertIsNone(llmctl.classify_server("Safari", "/Applications/Safari.app"))

    def test_a_process_merely_mentioning_llama_is_not_a_server(self):
        """"llama" appearing in a path is not a server; only the binary name is."""
        self.assertIsNone(llmctl.classify_server("bash", "cat ~/models/llama-3-8b/notes.txt"))


class PSTable(unittest.TestCase):
    """`ps` truncates a column to a fixed width when another column follows it.

    MEASURED: `ps -Ao pid=,uid=,rss=,comm=,args=` reported mediaanalysisd's comm
    as the literal string "/System/Library/", whose basename is empty -- which
    printed a process with no name -- and reported LocalAI's comm as
    "/opt/homebrew/bin/", which silently defeated the `endswith("local-ai")`
    test and hid a running server. Hence one ps call per field, each with that
    field last.
    """

    def test_pid_map_keeps_a_path_containing_spaces_intact(self):
        text = ("  425 /System/Library/PrivateFrameworks/MediaAnalysis.framework/"
                "Versions/A/mediaanalysisd\n"
                " 8962 /Applications/LM Studio.app/Contents/MacOS/LM Studio\n")
        m = llmctl.parse_pid_map(text)
        self.assertTrue(m[425].endswith("mediaanalysisd"))
        self.assertEqual(m[8962], "/Applications/LM Studio.app/Contents/MacOS/LM Studio")

    def test_pid_map_skips_headers_and_blanks(self):
        self.assertEqual(llmctl.parse_pid_map("  PID COMMAND\n\n  12\n"), {})

    def test_pid_numbers_requires_all_three_to_be_numeric(self):
        text = "  123   501  4194304\n  bad  501  10\n  456   501\n"
        nums = llmctl.parse_pid_numbers(text)
        self.assertEqual(nums, {123: ("501", 4194304 * 1024)})


class ServersFromTable(unittest.TestCase):
    ROWS = [
        {"pid": 123, "uid": "501", "rss": 4 * GB, "comm": "/path/llama-server",
         "args": "/path/llama-server --port 8080 --api-key abc"},
        {"pid": 456, "uid": "501", "rss": 512 * 1024 * 1024, "comm": "Python",
         "args": "python3 -m mlx_lm.server"},
        {"pid": 789, "uid": "501", "rss": 8 * 1024 * 1024, "comm": "Safari",
         "args": "/Applications/Safari.app/Contents/MacOS/Safari"},
        {"pid": 999, "uid": "0", "rss": 88 * 1024 * 1024,
         "comm": "/opt/homebrew/bin/local-ai", "args": "local-ai run --address :8080"},
    ]

    def test_only_servers_are_returned(self):
        servers = llmctl.servers_from_table(self.ROWS)
        self.assertEqual([s["kind"] for s in servers],
                         ["llama.cpp", "mlx-lm", "LocalAI"])
        self.assertEqual(servers[0]["pid"], 123)
        self.assertEqual(servers[0]["rss"], 4 * GB)

    def test_empty_table_is_no_servers(self):
        self.assertEqual(llmctl.servers_from_table([]), [])


class HogsFromTable(unittest.TestCase):
    ROWS = [
        {"pid": 1, "uid": "501", "rss": 3 * GB, "comm": "/Applications/Chrome",
         "args": "/Applications/Chrome --type=renderer"},
        {"pid": 2, "uid": "501", "rss": 2 * GB, "comm": "/path/llama-server",
         "args": "/path/llama-server --port 1"},
        {"pid": 3, "uid": "0", "rss": 9 * GB, "comm": "/usr/sbin/root-thing",
         "args": "/usr/sbin/root-thing"},
        {"pid": 4, "uid": "501", "rss": 10 * 1024 * 1024, "comm": "/bin/small",
         "args": "/bin/small"},
        {"pid": 5, "uid": "501", "rss": 1 * GB, "comm": "/System/Library/",
         "args": "/System/Library/PrivateFrameworks/A/mediaanalysisd"},
    ]

    def test_excludes_inference_engines_other_users_and_small_processes(self):
        hogs = llmctl.hogs_from_table(self.ROWS, "501")
        self.assertEqual([h[1] for h in hogs], [1, 5])       # sorted by size

    def test_recovers_a_name_when_comm_was_truncated_to_a_directory(self):
        hogs = llmctl.hogs_from_table(self.ROWS, "501")
        self.assertEqual(dict((h[1], h[2]) for h in hogs)[5], "mediaanalysisd")

    def test_limit_is_respected(self):
        self.assertEqual(len(llmctl.hogs_from_table(self.ROWS, "501", limit=1)), 1)


class PortAndKey(unittest.TestCase):
    def test_reads_both(self):
        argv = "llama-server --port 51234 --api-key s3cret --parallel 4".split()
        self.assertEqual(llmctl.port_and_key(argv), ("51234", "s3cret"))

    def test_underscore_spelling_is_accepted(self):
        argv = "llama-server --port 1 --api_key k".split()
        self.assertEqual(llmctl.port_and_key(argv), ("1", "k"))

    def test_missing_key_is_none_not_empty_string(self):
        port, key = llmctl.port_and_key("llama-server --port 8080".split())
        self.assertEqual(port, "8080")
        self.assertIsNone(key)

    def test_trailing_flag_without_a_value_does_not_index_past_the_end(self):
        self.assertEqual(llmctl.port_and_key(["llama-server", "--port"]), (None, None))


class Human(unittest.TestCase):
    def test_zero_is_a_dash_not_zero_bytes(self):
        self.assertEqual(llmctl.human(0), "-")

    def test_gigabytes_and_megabytes(self):
        self.assertEqual(llmctl.human(int(2.5 * GB)), "2.5 GB")
        self.assertEqual(llmctl.human(512 * 1024 * 1024), "512 MB")


class AIHints(unittest.TestCase):
    def test_the_hog_filter_excludes_every_engine_it_knows(self):
        """memory_hogs() must never list an inference engine as a hog to quit."""
        for args in ("/path/llama-server --port 1", "python3 -m mlx_lm.server",
                     "local-ai run", "ollama serve", "/Applications/Bionic.app/x",
                     "~/.lmstudio/bin/lms ps"):
            self.assertTrue(any(h in args for h in llmctl.AI_HINTS), args)

    def test_an_ordinary_app_is_not_excluded(self):
        self.assertFalse(any(h in "/Applications/Safari.app/Contents/MacOS/Safari"
                             for h in llmctl.AI_HINTS))


if __name__ == "__main__":
    unittest.main()


class LMSAutoLaunchGate(unittest.TestCase):
    """`lms` LAUNCHES LM Studio if it is not already running.

    That turned an earlier version of this tool into something that made the app
    un-quittable: quit it, and the next poll respawned it within seconds. So the
    CLI must be gated on the app already being up. These tests pin that shut.
    """

    def setUp(self):
        self.calls = []
        self._sh, self._http, self._proc = llmctl.sh, llmctl.http, llmctl.proc_rss
        self._lms = llmctl.LMS
        llmctl.LMS = "/bin/echo"          # exists, so os.path.exists() is not the gate
        llmctl.sh = lambda cmd, timeout=25: (self.calls.append(cmd), (1, "", ""))[1]
        llmctl.proc_rss = lambda patterns: (0, [])

    def tearDown(self):
        llmctl.sh, llmctl.http, llmctl.proc_rss = self._sh, self._http, self._proc
        llmctl.LMS = self._lms

    def _lms_was_called(self):
        return any(c and c[0] == "/bin/echo" for c in self.calls)

    def test_not_invoked_when_nothing_is_listening_and_no_process_matches(self):
        llmctl.http = lambda *a, **k: (None, b"")
        eng = llmctl.lmstudio()
        self.assertFalse(self._lms_was_called(), "lms must not be run: it would launch the app")
        self.assertFalse(eng["running"])
        self.assertEqual(eng["models"], [])

    def test_invoked_when_the_http_server_answers(self):
        llmctl.http = lambda *a, **k: (200, b'{"data": []}')
        llmctl.lmstudio()
        self.assertTrue(self._lms_was_called())

    def test_invoked_when_the_app_is_in_the_process_table(self):
        llmctl.http = lambda *a, **k: (None, b"")
        llmctl.proc_rss = lambda patterns: (
            (2 * GB, ["/Applications/LM Studio.app/x"])
            if any("app" in p.lower() for p in patterns) else (0, []))
        llmctl.lmstudio()
        self.assertTrue(self._lms_was_called())

    def test_free_reports_not_running_instead_of_launching_it(self):
        llmctl.http = lambda *a, **k: (None, b"")
        did, _, _ = llmctl.free("lmstudio")
        self.assertIn(("LM Studio", "not running"), did)
        self.assertFalse(self._lms_was_called())


class DisplayName(unittest.TestCase):
    def test_prefers_comm_and_keeps_spaces(self):
        self.assertEqual(llmctl.display_name("/Applications/LM Studio.app/MacOS/LM Studio",
                                             "/Applications/LM Studio.app/MacOS/LM Studio"),
                         "LM Studio")

    def test_falls_back_to_argv_when_comm_is_a_truncated_directory(self):
        self.assertEqual(llmctl.display_name("/System/Library/",
                                             "/System/Library/PrivateFrameworks/A/mediaanalysisd"),
                         "mediaanalysisd")

    def test_never_returns_empty(self):
        self.assertEqual(llmctl.display_name("", ""), "?")
        self.assertEqual(llmctl.display_name("/", ""), "?")
