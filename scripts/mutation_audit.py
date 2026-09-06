#!/usr/bin/env python3
"""Mutation audit for Shared/GLTodoOutbox.m against the SharedTests bundle.

For each mutation: assert the target snippet occurs exactly once in the
pristine file, apply it, run `xcodebuild test`, record which tests failed,
restore the pristine file. Results are appended to mutation-results.json as
they come in so a timeout still leaves partial evidence.
"""
import json, os, re, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TARGET = os.path.join(ROOT, "Shared", "GLTodoOutbox.m")
SIM = os.environ["SIM_UDID"]
RESULTS = os.path.join(ROOT, "mutation-results.json")
LOGDIR = os.path.join(ROOT, "mutation-logs")
os.makedirs(LOGDIR, exist_ok=True)

PRISTINE = open(TARGET).read()

# (id, description, old, new). `old` must occur exactly once.
MUTATIONS = [
    # --- delegate / classification seam (didCompleteWithError) ---
    ("D1", "captive portal: any 2xx counts as sent (body check bypassed at the seam)",
     "} else if ([GLTodoOutbox responseBodyIndicatesSuccess:body]) {",
     "} else if (YES) {"),
    ("D3", "transport error (offline) counts as sent",
     "outcome = GLTodoOutboxOutcomeTransportError;\n            reportedStatus = 0;\n        } else if (status < 200",
     "outcome = GLTodoOutboxOutcomeSuccess;\n            reportedStatus = 0;\n        } else if (status < 200"),
    ("D2", "non-2xx never classified as HTTP error",
     "} else if (status < 200 || status > 299) {",
     "} else if (status < 200 && status > 299) {"),
    ("D4", "completion outcome never persisted to disk",
     "GLTodoOutboxState *next = [current stateByApplyingOutcome:outcome status:reportedStatus];\n        [self persistState:next];",
     "GLTodoOutboxState *next = [current stateByApplyingOutcome:outcome status:reportedStatus];\n        (void)next;"),
    ("D5", "chain never continues after a success",
     "if (outcome == GLTodoOutboxOutcomeSuccess) {\n            [self startNextUploadIfNeeded];\n        }",
     ""),
    ("D6", "stale-task identity guard removed (late callback applies to whatever is on disk)",
     "if (task != self.activeTask) return;",
     ""),
    ("D7", "reclaim cancels but does not clear activeTask (next handoff can never start)",
     "[self.activeTask cancel];\n            self.activeTask = nil;",
     "[self.activeTask cancel];"),
    ("D8", "reclaim clears activeTask but does not cancel the in-flight task",
     "[self.activeTask cancel];\n            self.activeTask = nil;",
     "self.activeTask = nil;"),
    # --- handoff / sequencing ---
    ("H1", "identical-ops idempotency guard removed",
     "if ([incomingIds isEqualToArray:currentIds]) {\n            return (NSInteger)ops.count;\n        }",
     ""),
    ("H2", "one-in-flight gate removed (second task can be created concurrently)",
     "if (self.activeTask != nil) return; // one in flight already -- never start a second",
     ""),
    ("H3", "handoff starts the upload BEFORE persisting",
     "[self persistState:newState];\n        [self startNextUploadIfNeeded];",
     "[self startNextUploadIfNeeded];\n        [self persistState:newState];"),
    # --- persistence ---
    ("P1", "`sent` never written to disk",
     "@\"sent\": sent,",
     "@\"sent\": @[],"),
    ("P2", "`failed` never written to disk (relaunch would retry the failed op)",
     "@\"failed\": state.failed ?: [NSNull null],\n    };",
     "@\"failed\": [NSNull null],\n    };"),
    ("P3", "`remaining` order reversed on load",
     "NSArray<GLTodoOutboxOp *> *remaining = [self opsFromArray:dict[@\"remaining\"]];",
     "NSArray<GLTodoOutboxOp *> *remaining = [[[self opsFromArray:dict[@\"remaining\"]] reverseObjectEnumerator] allObjects];"),
    ("P4", "persist writes an empty file",
     "if (![data writeToURL:self.storeURL options:NSDataWritingAtomic error:&writeError]) {",
     "if (![[NSData data] writeToURL:self.storeURL options:NSDataWritingAtomic error:&writeError]) {"),
    # --- request construction ---
    ("R1", "opId not injected into the POST body (server cannot dedupe)",
     "payload[@\"opId\"] = op.opId;",
     ""),
    ("R2", "POST becomes GET",
     "request.HTTPMethod = @\"POST\";",
     "request.HTTPMethod = @\"GET\";"),
    ("R3", "op.path dropped from the URL",
     "[NSString stringWithFormat:@\"%@%@\", self.serverBase, op.path]",
     "[NSString stringWithFormat:@\"%@\", self.serverBase]"),
    # --- state machine ---
    ("S1", "halt-on-failure removed from nextOpToSend",
     "if (self.failed != nil) return nil;\n    return self.remaining.firstObject;",
     "return self.remaining.firstObject;"),
    ("S2", "success keeps a stale `failed` instead of clearing it",
     "initWithRemaining:newRemaining sent:newSent failed:nil]",
     "initWithRemaining:newRemaining sent:newSent failed:self.failed]"),
    ("S3", "`sent` replaced by the head instead of appended",
     "[self.sent arrayByAddingObject:head]",
     "@[head]"),
    ("S4", "success drops the TAIL op instead of the head",
     "[self.remaining subarrayWithRange:NSMakeRange(1, self.remaining.count - 1)]",
     "[self.remaining subarrayWithRange:NSMakeRange(0, self.remaining.count - 1)]"),
    ("S5", "failure skips the head op",
     "return [[GLTodoOutboxState alloc] initWithRemaining:self.remaining\n                                                    sent:self.sent",
     "return [[GLTodoOutboxState alloc] initWithRemaining:(self.remaining.count > 1 ? [self.remaining subarrayWithRange:NSMakeRange(1, self.remaining.count - 1)] : @[])\n                                                    sent:self.sent"),
    ("S6", "failure always records status 0",
     "@\"status\": @(status)}",
     "@\"status\": @0}"),
    ("S7", "failure records the LAST op's id instead of the head's",
     "failed:@{@\"opId\": head.opId,",
     "failed:@{@\"opId\": self.remaining.lastObject.opId,"),
    # --- body check ---
    ("B1", "any JSON object counts as success (ok ignored)",
     "return [ok isKindOfClass:[NSNumber class]] && [(NSNumber *)ok boolValue];",
     "return YES;"),
    ("B2", "empty body counts as success",
     "if (data.length == 0) return NO;",
     "if (data.length == 0) return YES;"),
    ("B3", "non-JSON (HTML) body counts as success",
     "if (error || ![parsed isKindOfClass:[NSDictionary class]]) return NO;\n    id ok",
     "if (error || ![parsed isKindOfClass:[NSDictionary class]]) return YES;\n    id ok"),
    # --- op parsing ---
    ("O1", "empty-string opId accepted",
     "if (![opId isKindOfClass:[NSString class]] || opId.length == 0) return nil;",
     "if (![opId isKindOfClass:[NSString class]]) return nil;"),
]

FAILED_RE = re.compile(r"Test Case '-\[(\w+) (\w+)\]' failed")
PASSED_RE = re.compile(r"Test Case '-\[(\w+) (\w+)\]' passed")
EXEC_RE = re.compile(r"Executed (\d+) tests?, with (\d+) failures?")


def run_tests(tag):
    cmd = [
        "xcodebuild", "test", "-project", "Overland.xcodeproj", "-scheme", "SharedTests",
        "-destination", f"id={SIM}", "-derivedDataPath", "build", "CODE_SIGNING_ALLOWED=NO",
    ]
    t0 = time.time()
    p = subprocess.run(cmd, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    out = p.stdout
    open(os.path.join(LOGDIR, f"{tag}.log"), "w").write(out)
    failed = sorted({f"{c}.{m}" for c, m in FAILED_RE.findall(out)})
    passed = sorted({f"{c}.{m}" for c, m in PASSED_RE.findall(out)})
    execs = EXEC_RE.findall(out)
    executed = max((int(n) for n, _ in execs), default=0)
    build_failed = "** BUILD FAILED **" in out or "** TEST FAILED **" in out and executed == 0
    return {
        "exit": p.returncode, "seconds": round(time.time() - t0, 1),
        "executed": executed, "failed": failed, "passed_count": len(passed),
        "build_failed": build_failed,
    }


results = []


def record(entry):
    results.append(entry)
    json.dump(results, open(RESULTS, "w"), indent=2)
    print(f"::group::{entry['id']} {entry['desc']}")
    print(json.dumps(entry, indent=2))
    print("::endgroup::")
    sys.stdout.flush()


def restore():
    open(TARGET, "w").write(PRISTINE)
    diff = subprocess.run(["git", "diff", "--quiet", "--", TARGET], cwd=ROOT)
    assert diff.returncode == 0, "file not restored to git HEAD"


# Baseline: pristine file must be green with 21 executed.
base = run_tests("baseline")
record({"id": "BASELINE", "desc": "pristine", **base})
if base["executed"] != 21 or base["failed"]:
    print("BASELINE NOT GREEN -- aborting, mutation results would be meaningless")
    sys.exit(2)

only = os.environ.get("MUTATIONS")  # optional comma list to run a subset
for mid, desc, old, new in MUTATIONS:
    if only and mid not in only.split(","):
        continue
    n = PRISTINE.count(old)
    if n != 1:
        record({"id": mid, "desc": desc, "error": f"target snippet occurs {n} times, expected 1"})
        continue
    open(TARGET, "w").write(PRISTINE.replace(old, new))
    try:
        r = run_tests(mid)
    finally:
        restore()
    verdict = "BUILD_FAILED" if r["build_failed"] else ("KILLED" if r["failed"] else "SURVIVED")
    record({"id": mid, "desc": desc, "verdict": verdict, **r})

print("\n=== SUMMARY ===")
for r in results:
    print(f"{r['id']:9} {r.get('verdict', r.get('error', '')):13} exec={r.get('executed')} failed={r.get('failed')}  {r['desc']}")
