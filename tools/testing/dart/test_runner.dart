// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/**
 * Classes and methods for executing tests.
 *
 * This module includes:
 * - Managing parallel execution of tests, including timeout checks.
 * - Evaluating the output of each test as pass/fail/crash/timeout.
 */
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
// We need to use the 'io' prefix here, otherwise io.exitCode will shadow
// CommandOutput.exitCode in subclasses of CommandOutput.
import 'dart:io' as io;
import 'dart:math' as math;

import "package:status_file/expectation.dart";

import 'android.dart';
import 'browser_controller.dart';
import 'command.dart';
import 'command_output.dart';
import 'configuration.dart';
import 'dependency_graph.dart';
import 'repository.dart';
import 'runtime_configuration.dart';
import 'test_progress.dart';
import 'test_suite.dart';
import 'utils.dart';

const int unhandledCompilerExceptionExitCode = 253;
const int parseFailExitCode = 245;
const int slowTimeoutMultiplier = 4;
const int extraSlowTimeoutMultiplier = 8;
const int nonUtfFakeExitCode = 0xFFFD;

const cannotOpenDisplayMessage = 'Gtk-WARNING **: cannot open display';
const failedToRunCommandMessage = 'Failed to run command. return code=1';

typedef void TestCaseEvent(TestCase testCase);
typedef void ExitCodeEvent(int exitCode);
typedef void EnqueueMoreWork(ProcessQueue queue);
typedef void Action();
typedef Future<AdbCommandResult> StepFunction();

/// Some IO tests use these variables and get confused if the host environment
/// variables are inherited so they are excluded.
const _excludedEnvironmentVariables = const [
  'http_proxy',
  'https_proxy',
  'no_proxy',
  'HTTP_PROXY',
  'HTTPS_PROXY',
  'NO_PROXY'
];

/**
 * TestCase contains all the information needed to run a test and evaluate
 * its output.  Running a test involves starting a separate process, with
 * the executable and arguments given by the TestCase, and recording its
 * stdout and stderr output streams, and its exit code.  TestCase only
 * contains static information about the test; actually running the test is
 * performed by [ProcessQueue] using a [RunningProcess] object.
 *
 * The output information is stored in a [CommandOutput] instance contained
 * in TestCase.commandOutputs. The last CommandOutput instance is responsible
 * for evaluating if the test has passed, failed, crashed, or timed out, and the
 * TestCase has information about what the expected result of the test should
 * be.
 *
 * The TestCase has a callback function, [completedHandler], that is run when
 * the test is completed.
 */
class TestCase extends UniqueObject {
  // Flags set in _expectations from the optional argument info.
  static final int HAS_RUNTIME_ERROR = 1 << 0;
  static final int HAS_SYNTAX_ERROR = 1 << 1;
  static final int HAS_COMPILE_ERROR = 1 << 2;
  static final int HAS_STATIC_WARNING = 1 << 3;
  static final int HAS_CRASH = 1 << 4;
  /**
   * A list of commands to execute. Most test cases have a single command.
   * Dart2js tests have two commands, one to compile the source and another
   * to execute it. Some isolate tests might even have three, if they require
   * compiling multiple sources that are run in isolation.
   */
  List<Command> commands;
  Map<Command, CommandOutput> commandOutputs =
      new Map<Command, CommandOutput>();

  TestConfiguration configuration;
  String displayName;
  int _expectations = 0;
  int hash = 0;
  Set<Expectation> expectedOutcomes;

  TestCase(this.displayName, this.commands, this.configuration,
      this.expectedOutcomes,
      {TestInformation info}) {
    // A test case should do something.
    assert(commands.isNotEmpty);

    if (info != null) {
      _setExpectations(info);
      hash = (info?.originTestPath?.relativeTo(Repository.dir)?.toString())
          .hashCode;
    }
  }

  void _setExpectations(TestInformation info) {
    // We don't want to keep the entire (large) TestInformation structure,
    // so we copy the needed bools into flags set in a single integer.
    if (info.hasRuntimeError) _expectations |= HAS_RUNTIME_ERROR;
    if (info.hasSyntaxError) _expectations |= HAS_SYNTAX_ERROR;
    if (info.hasCrash) _expectations |= HAS_CRASH;
    if (info.hasCompileError || info.hasSyntaxError) {
      _expectations |= HAS_COMPILE_ERROR;
    }
    if (info.hasStaticWarning) _expectations |= HAS_STATIC_WARNING;
  }

  TestCase indexedCopy(int index) {
    var newCommands = commands.map((c) => c.indexedCopy(index)).toList();
    return new TestCase(
        displayName, newCommands, configuration, expectedOutcomes)
      .._expectations = _expectations
      ..hash = hash;
  }

  bool get hasRuntimeError => _expectations & HAS_RUNTIME_ERROR != 0;
  bool get hasStaticWarning => _expectations & HAS_STATIC_WARNING != 0;
  bool get hasSyntaxError => _expectations & HAS_SYNTAX_ERROR != 0;
  bool get hasCompileError => _expectations & HAS_COMPILE_ERROR != 0;
  bool get hasCrash => _expectations & HAS_CRASH != 0;
  bool get isNegative =>
      hasCompileError ||
      hasRuntimeError && configuration.runtime != Runtime.none ||
      displayName.contains("negative_test");

  bool get unexpectedOutput {
    var outcome = this.result;
    return !expectedOutcomes.any((expectation) {
      return outcome.canBeOutcomeOf(expectation);
    });
  }

  Expectation get result => lastCommandOutput.result(this);
  Expectation get realResult => lastCommandOutput.realResult(this);
  Expectation get realExpected {
    if (hasCrash) {
      return Expectation.crash;
    }
    if (configuration.compiler == Compiler.specParser) {
      if (hasSyntaxError) {
        return Expectation.syntaxError;
      }
    } else if (hasCompileError) {
      if (hasRuntimeError && configuration.runtime != Runtime.none) {
        return Expectation.fail;
      }
      return Expectation.compileTimeError;
    }
    if (hasRuntimeError) {
      if (configuration.runtime != Runtime.none) {
        return Expectation.runtimeError;
      }
      return Expectation.pass;
    }
    if (displayName.contains("negative_test")) {
      return Expectation.fail;
    }
    if (configuration.compiler == Compiler.dart2analyzer && hasStaticWarning) {
      return Expectation.staticWarning;
    }
    return Expectation.pass;
  }

  CommandOutput get lastCommandOutput {
    if (commandOutputs.length == 0) {
      throw new Exception("CommandOutputs is empty, maybe no command was run? ("
          "displayName: '$displayName', "
          "configurationString: '$configurationString')");
    }
    return commandOutputs[commands[commandOutputs.length - 1]];
  }

  Command get lastCommandExecuted {
    if (commandOutputs.length == 0) {
      throw new Exception("CommandOutputs is empty, maybe no command was run? ("
          "displayName: '$displayName', "
          "configurationString: '$configurationString')");
    }
    return commands[commandOutputs.length - 1];
  }

  int get timeout {
    var result = configuration.timeout;
    if (expectedOutcomes.contains(Expectation.slow)) {
      result *= slowTimeoutMultiplier;
    } else if (expectedOutcomes.contains(Expectation.extraSlow)) {
      result *= extraSlowTimeoutMultiplier;
    }
    return result;
  }

  String get configurationString {
    var compiler = configuration.compiler.name;
    var runtime = configuration.runtime.name;
    var mode = configuration.mode.name;
    var arch = configuration.architecture.name;
    var checked = configuration.isChecked ? '-checked' : '';
    return "$compiler-$runtime$checked ${mode}_$arch";
  }

  List<String> get batchTestArguments {
    assert(commands.last is ProcessCommand);
    return (commands.last as ProcessCommand).arguments;
  }

  bool get isFlaky {
    if (expectedOutcomes.contains(Expectation.skip) ||
        expectedOutcomes.contains(Expectation.skipByDesign)) {
      return false;
    }

    return expectedOutcomes
            .where((expectation) => expectation.isOutcome)
            .length >
        1;
  }

  bool get isFinished {
    return commandOutputs.length > 0 &&
        (!lastCommandOutput.successful ||
            commands.length == commandOutputs.length);
  }
}

/**
 * An OutputLog records the output from a test, but truncates it if
 * it is longer than MAX_HEAD characters, and just keeps the head and
 * the last TAIL_LENGTH characters of the output.
 */
class OutputLog implements StreamConsumer<List<int>> {
  static const int MAX_HEAD = 500 * 1024;
  static const int TAIL_LENGTH = 10 * 1024;
  List<int> head = <int>[];
  List<int> tail;
  List<int> complete;
  bool dataDropped = false;
  bool hasNonUtf8 = false;
  StreamSubscription _subscription;

  OutputLog();

  void add(List<int> data) {
    if (complete != null) {
      throw new StateError("Cannot add to OutputLog after calling toList");
    }
    if (tail == null) {
      head.addAll(data);
      if (head.length > MAX_HEAD) {
        tail = head.sublist(MAX_HEAD);
        head.length = MAX_HEAD;
      }
    } else {
      tail.addAll(data);
    }
    if (tail != null && tail.length > 2 * TAIL_LENGTH) {
      tail = _truncatedTail();
      dataDropped = true;
    }
  }

  List<int> _truncatedTail() => tail.length > TAIL_LENGTH
      ? tail.sublist(tail.length - TAIL_LENGTH)
      : tail;

  void _checkUtf8(List<int> data) {
    try {
      utf8.decode(data, allowMalformed: false);
    } on FormatException {
      hasNonUtf8 = true;
      String malformed = utf8.decode(data, allowMalformed: true);
      data
        ..clear()
        ..addAll(utf8.encode(malformed))
        ..addAll("""

  *****************************************************************************

  test.dart: The output of this test contained non-UTF8 formatted data.

  *****************************************************************************

  """
            .codeUnits);
    }
  }

  List<int> toList() {
    if (complete == null) {
      complete = head;
      if (dataDropped) {
        complete.addAll("""

*****************************************************************************

test.dart: Data was removed due to excessive length. If you need the limit to
be increased, please contact dart-engprod or file an issue.

*****************************************************************************

"""
            .codeUnits);
        complete.addAll(_truncatedTail());
      } else if (tail != null) {
        complete.addAll(tail);
      }
      head = null;
      tail = null;
      _checkUtf8(complete);
    }
    return complete;
  }

  @override
  Future addStream(Stream<List<int>> stream) {
    _subscription = stream.listen(this.add);
    return _subscription.asFuture();
  }

  @override
  Future close() {
    toList();
    return _subscription?.cancel();
  }

  Future cancel() {
    return _subscription?.cancel();
  }
}

// An [OutputLog] that tees the output to a file as well.
class FileOutputLog extends OutputLog {
  io.File _outputFile;
  io.IOSink _sink;

  FileOutputLog(this._outputFile);

  @override
  void add(List<int> data) {
    super.add(data);
    _sink ??= _outputFile.openWrite();
    _sink.add(data);
  }

  @override
  Future close() {
    return Future.wait([
      super.close(),
      if (_sink != null) _sink.flush().whenComplete(_sink.close)
    ]);
  }

  @override
  Future cancel() {
    return Future.wait([
      super.cancel(),
      if (_sink != null) _sink.flush().whenComplete(_sink.close)
    ]);
  }
}

// Helper to get a list of all child pids for a parent process.
// The first element of the list is the parent pid.
Future<List<int>> _getPidList(int pid, List<String> diagnostics) async {
  var pids = [pid];
  List<String> lines;
  var startLine = 0;
  if (io.Platform.isLinux || io.Platform.isMacOS) {
    var result =
        await io.Process.run("pgrep", ["-P", "${pids[0]}"], runInShell: true);
    lines = (result.stdout as String).split('\n');
  } else if (io.Platform.isWindows) {
    var result = await io.Process.run(
        "wmic",
        [
          "process",
          "where",
          "(ParentProcessId=${pids[0]})",
          "get",
          "ProcessId"
        ],
        runInShell: true);
    lines = (result.stdout as String).split('\n');
    // Skip first line containing header "ProcessId".
    startLine = 1;
  } else {
    assert(false);
  }
  if (lines.length > startLine) {
    for (var i = startLine; i < lines.length; ++i) {
      var pid = int.tryParse(lines[i]);
      if (pid != null) pids.add(pid);
    }
  } else {
    diagnostics.add("Could not find child pids");
    diagnostics.addAll(lines);
  }
  return pids;
}

/**
 * A RunningProcess actually runs a test, getting the command lines from
 * its [TestCase], starting the test process (and first, a compilation
 * process if the TestCase is a [BrowserTestCase]), creating a timeout
 * timer, and recording the results in a new [CommandOutput] object, which it
 * attaches to the TestCase.  The lifetime of the RunningProcess is limited
 * to the time it takes to start the process, run the process, and record
 * the result; there are no pointers to it, so it should be available to
 * be garbage collected as soon as it is done.
 */
class RunningProcess {
  ProcessCommand command;
  int timeout;
  bool timedOut = false;
  DateTime startTime;
  int pid;
  OutputLog stdout;
  OutputLog stderr = OutputLog();
  List<String> diagnostics = <String>[];
  bool compilationSkipped = false;
  Completer<CommandOutput> completer;
  TestConfiguration configuration;

  RunningProcess(this.command, this.timeout,
      {this.configuration, io.File outputFile}) {
    stdout = outputFile != null ? FileOutputLog(outputFile) : OutputLog();
  }

  Future<CommandOutput> run() {
    completer = new Completer<CommandOutput>();
    startTime = new DateTime.now();
    _runCommand();
    return completer.future;
  }

  void _runCommand() {
    if (command.outputIsUpToDate) {
      compilationSkipped = true;
      _commandComplete(0);
    } else {
      var processEnvironment = _createProcessEnvironment();
      var args = command.arguments;
      var processFuture = io.Process.start(command.executable, args,
          environment: processEnvironment,
          workingDirectory: command.workingDirectory);
      processFuture.then((io.Process process) {
        var stdoutFuture = process.stdout.pipe(stdout);
        var stderrFuture = process.stderr.pipe(stderr);
        pid = process.pid;

        // Close stdin so that tests that try to block on input will fail.
        process.stdin.close();
        timeoutHandler() async {
          timedOut = true;
          if (process != null) {
            String executable;
            if (io.Platform.isLinux) {
              executable = 'eu-stack';
            } else if (io.Platform.isMacOS) {
              // Try to print stack traces of the timed out process.
              // `sample` is a sampling profiler but we ask it sample for 1
              // second with a 4 second delay between samples so that we only
              // sample the threads once.
              executable = '/usr/bin/sample';
            } else if (io.Platform.isWindows) {
              var isX64 = command.executable.contains("X64") ||
                  command.executable.contains("SIMARM64");
              if (configuration.windowsSdkPath != null) {
                executable = configuration.windowsSdkPath +
                    "\\Debuggers\\${isX64 ? 'x64' : 'x86'}\\cdb.exe";
                diagnostics.add("Using $executable to print stack traces");
              } else {
                diagnostics.add("win_sdk_path not found");
              }
            } else {
              diagnostics.add("Capturing stack traces on"
                  "${io.Platform.operatingSystem} not supported");
            }
            if (executable != null) {
              var pids = await _getPidList(process.pid, diagnostics);
              diagnostics.add("Process list including children: $pids");
              for (pid in pids) {
                List<String> arguments;
                if (io.Platform.isLinux) {
                  arguments = ['-p $pid'];
                } else if (io.Platform.isMacOS) {
                  arguments = ['$pid', '1', '4000', '-mayDie'];
                } else if (io.Platform.isWindows) {
                  arguments = ['-p', '$pid', '-c', '!uniqstack;qd'];
                } else {
                  assert(false);
                }
                diagnostics.add("Trying to capture stack trace for pid $pid");
                try {
                  var result = await io.Process.run(executable, arguments);
                  diagnostics.addAll((result.stdout as String).split('\n'));
                  diagnostics.addAll((result.stderr as String).split('\n'));
                } catch (error) {
                  diagnostics.add("Unable to capture stack traces: $error");
                }
              }
            }

            if (!process.kill()) {
              diagnostics.add("Unable to kill ${process.pid}");
            }
          }
        }

        // Wait for the process to finish or timeout
        process.exitCode
            .timeout(Duration(seconds: timeout), onTimeout: timeoutHandler)
            .then((exitCode) {
          // This timeout is used to close stdio to the subprocess once we got
          // the exitCode. Sometimes descendants of the subprocess keep stdio
          // handles alive even though the direct subprocess is dead.
          Future.wait([stdoutFuture, stderrFuture]).timeout(MAX_STDIO_DELAY,
              onTimeout: () async {
            DebugLogger.warning(
                "$MAX_STDIO_DELAY_PASSED_MESSAGE (command: $command)");
            await stdout.cancel();
            await stderr.cancel();
            _commandComplete(exitCode);
            return null;
          }).then((_) {
            if (stdout is FileOutputLog) {
              // Prevent logging data that has already been written to a file
              // and is unlikely too add value in the logs because the command
              // succeeded.
              stdout.complete = <int>[];
            }
            _commandComplete(exitCode);
          });
        });
      }).catchError((e) {
        // TODO(floitsch): should we try to report the stacktrace?
        print("Process error:");
        print("  Command: $command");
        print("  Error: $e");
        _commandComplete(-1);
        return true;
      });
    }
  }

  void _commandComplete(int exitCode) {
    var commandOutput = _createCommandOutput(command, exitCode);
    completer.complete(commandOutput);
  }

  CommandOutput _createCommandOutput(ProcessCommand command, int exitCode) {
    List<int> stdoutData = stdout.toList();
    List<int> stderrData = stderr.toList();
    if (stdout.hasNonUtf8 || stderr.hasNonUtf8) {
      // If the output contained non-utf8 formatted data, then make the exit
      // code non-zero if it isn't already.
      if (exitCode == 0) {
        exitCode = nonUtfFakeExitCode;
      }
    }
    var commandOutput = createCommandOutput(
        command,
        exitCode,
        timedOut,
        stdoutData,
        stderrData,
        new DateTime.now().difference(startTime),
        compilationSkipped,
        pid);
    commandOutput.diagnostics.addAll(diagnostics);
    return commandOutput;
  }

  Map<String, String> _createProcessEnvironment() {
    var environment = new Map<String, String>.from(io.Platform.environment);

    if (command.environmentOverrides != null) {
      for (var key in command.environmentOverrides.keys) {
        environment[key] = command.environmentOverrides[key];
      }
    }
    for (var excludedEnvironmentVariable in _excludedEnvironmentVariables) {
      environment.remove(excludedEnvironmentVariable);
    }

    // TODO(terry): Needed for roll 50?
    environment["GLIBCPP_FORCE_NEW"] = "1";
    environment["GLIBCXX_FORCE_NEW"] = "1";

    return environment;
  }
}

class BatchRunnerProcess {
  /// When true, the command line is passed to the test runner as a
  /// JSON-encoded list of strings.
  final bool _useJson;

  Completer<CommandOutput> _completer;
  ProcessCommand _command;
  List<String> _arguments;
  String _runnerType;

  io.Process _process;
  Map<String, String> _processEnvironmentOverrides;
  Completer<Null> _stdoutCompleter;
  Completer<Null> _stderrCompleter;
  StreamSubscription<String> _stdoutSubscription;
  StreamSubscription<String> _stderrSubscription;
  Function _processExitHandler;

  bool _currentlyRunning = false;
  OutputLog _testStdout;
  OutputLog _testStderr;
  String _status;
  DateTime _startTime;
  Timer _timer;
  int _testCount = 0;

  BatchRunnerProcess({bool useJson: true}) : _useJson = useJson;

  Future<CommandOutput> runCommand(String runnerType, ProcessCommand command,
      int timeout, List<String> arguments) {
    assert(_completer == null);
    assert(!_currentlyRunning);

    _completer = new Completer();
    bool sameRunnerType = _runnerType == runnerType &&
        _dictEquals(_processEnvironmentOverrides, command.environmentOverrides);
    _runnerType = runnerType;
    _currentlyRunning = true;
    _command = command;
    _arguments = arguments;
    _processEnvironmentOverrides = command.environmentOverrides;

    // TOOD(jmesserly): this restarts `dartdevc --batch` to work around a
    // memory leak, see https://github.com/dart-lang/sdk/issues/30314.
    var clearMemoryLeak = command is CompilationCommand &&
        command.displayName == 'dartdevc' &&
        ++_testCount % 100 == 0;
    if (_process == null) {
      // Start process if not yet started.
      _startProcess(() {
        doStartTest(command, timeout);
      });
    } else if (!sameRunnerType || clearMemoryLeak) {
      // Restart this runner with the right executable for this test if needed.
      _processExitHandler = (_) {
        _startProcess(() {
          doStartTest(command, timeout);
        });
      };
      _process.kill();
      _stdoutSubscription.cancel();
      _stderrSubscription.cancel();
    } else {
      doStartTest(command, timeout);
    }
    return _completer.future;
  }

  Future<bool> terminate() {
    if (_process == null) return new Future.value(true);
    var terminateCompleter = new Completer<bool>();
    _processExitHandler = (_) {
      terminateCompleter.complete(true);
    };
    _process.kill();
    _stdoutSubscription.cancel();
    _stderrSubscription.cancel();

    return terminateCompleter.future;
  }

  void doStartTest(Command command, int timeout) {
    _startTime = new DateTime.now();
    _testStdout = new OutputLog();
    _testStderr = new OutputLog();
    _status = null;
    _stdoutCompleter = new Completer();
    _stderrCompleter = new Completer();
    _timer = new Timer(new Duration(seconds: timeout), _timeoutHandler);

    var line = _createArgumentsLine(_arguments, timeout);
    _process.stdin.write(line);
    _stdoutSubscription.resume();
    _stderrSubscription.resume();
    Future.wait([_stdoutCompleter.future, _stderrCompleter.future])
        .then((_) => _reportResult());
  }

  String _createArgumentsLine(List<String> arguments, int timeout) {
    if (_useJson) {
      return "${jsonEncode(arguments)}\n";
    } else {
      return arguments.join(' ') + '\n';
    }
  }

  void _reportResult() {
    if (!_currentlyRunning) return;
    // _status == '>>> TEST {PASS, FAIL, OK, CRASH, TIMEOUT, PARSE_FAIL}'

    var outcome = _status.split(" ")[2];
    var exitCode = 0;
    if (outcome == "CRASH") exitCode = unhandledCompilerExceptionExitCode;
    if (outcome == "PARSE_FAIL") exitCode = parseFailExitCode;
    if (outcome == "FAIL" || outcome == "TIMEOUT") exitCode = 1;
    var output = createCommandOutput(
        _command,
        exitCode,
        (outcome == "TIMEOUT"),
        _testStdout.toList(),
        _testStderr.toList(),
        new DateTime.now().difference(_startTime),
        false);
    assert(_completer != null);
    _completer.complete(output);
    _completer = null;
    _currentlyRunning = false;
  }

  ExitCodeEvent makeExitHandler(String status) {
    void handler(int exitCode) {
      if (_currentlyRunning) {
        if (_timer != null) _timer.cancel();
        _status = status;
        _stdoutSubscription.cancel();
        _stderrSubscription.cancel();
        _startProcess(_reportResult);
      } else {
        // No active test case running.
        _process = null;
      }
    }

    return handler;
  }

  void _timeoutHandler() {
    _processExitHandler = makeExitHandler(">>> TEST TIMEOUT");
    _process.kill();
  }

  void _startProcess(Action callback) {
    assert(_command is ProcessCommand);
    var executable = _command.executable;
    var arguments = _command.batchArguments.toList();
    arguments.add('--batch');
    var environment = new Map<String, String>.from(io.Platform.environment);
    if (_processEnvironmentOverrides != null) {
      for (var key in _processEnvironmentOverrides.keys) {
        environment[key] = _processEnvironmentOverrides[key];
      }
    }
    var processFuture =
        io.Process.start(executable, arguments, environment: environment);
    processFuture.then((io.Process p) {
      _process = p;

      Stream<String> _stdoutStream =
          _process.stdout.transform(utf8.decoder).transform(new LineSplitter());
      _stdoutSubscription = _stdoutStream.listen((String line) {
        if (line.startsWith('>>> TEST')) {
          _status = line;
        } else if (line.startsWith('>>> BATCH')) {
          // ignore
        } else if (line.startsWith('>>> ')) {
          throw new Exception("Unexpected command from batch runner: '$line'.");
        } else {
          _testStdout.add(encodeUtf8(line));
          _testStdout.add("\n".codeUnits);
        }
        if (_status != null) {
          _stdoutSubscription.pause();
          _timer.cancel();
          _stdoutCompleter.complete(null);
        }
      });
      _stdoutSubscription.pause();

      Stream<String> _stderrStream =
          _process.stderr.transform(utf8.decoder).transform(new LineSplitter());
      _stderrSubscription = _stderrStream.listen((String line) {
        if (line.startsWith('>>> EOF STDERR')) {
          _stderrSubscription.pause();
          _stderrCompleter.complete(null);
        } else {
          _testStderr.add(encodeUtf8(line));
          _testStderr.add("\n".codeUnits);
        }
      });
      _stderrSubscription.pause();

      _processExitHandler = makeExitHandler(">>> TEST CRASH");
      _process.exitCode.then((exitCode) {
        _processExitHandler(exitCode);
      });

      _process.stdin.done.catchError((err) {
        print('Error on batch runner input stream stdin');
        print('  Previous test\'s status: $_status');
        print('  Error: $err');
        throw err;
      });
      callback();
    }).catchError((e) {
      // TODO(floitsch): should we try to report the stacktrace?
      print("Process error:");
      print("  Command: $executable ${arguments.join(' ')} ($_arguments)");
      print("  Error: $e");
      // If there is an error starting a batch process, chances are that
      // it will always fail. So rather than re-trying a 1000+ times, we
      // exit.
      io.exit(1);
      return true;
    });
  }

  bool _dictEquals(Map a, Map b) {
    if (a == null) return b == null;
    if (b == null) return false;
    if (a.length != b.length) return false;
    for (var key in a.keys) {
      if (a[key] != b[key]) return false;
    }
    return true;
  }
}

/**
 * [TestCaseEnqueuer] takes a list of TestSuites, generates TestCases and
 * builds a dependency graph of all commands in every TestSuite.
 *
 * It will maintain three helper data structures
 *  - command2node: A mapping from a [Command] to a node in the dependency graph
 *  - command2testCases: A mapping from [Command] to all TestCases that it is
 *    part of.
 *  - remainingTestCases: A set of TestCases that were enqueued but are not
 *    finished
 *
 * [Command] and it's subclasses all have hashCode/operator== methods defined
 * on them, so we can safely use them as keys in Map/Set objects.
 */
class TestCaseEnqueuer {
  final Graph<Command> graph;
  final Function _onTestCaseAdded;

  final command2node = <Command, Node<Command>>{};
  final command2testCases = <Command, List<TestCase>>{};
  final remainingTestCases = new Set<TestCase>();

  TestCaseEnqueuer(this.graph, this._onTestCaseAdded);

  void enqueueTestSuites(List<TestSuite> testSuites) {
    // Cache information about test cases per test suite. For multiple
    // configurations there is no need to repeatedly search the file
    // system, generate tests, and search test files for options.
    var testCache = <String, List<TestInformation>>{};

    var iterator = testSuites.iterator;
    void enqueueNextSuite() {
      if (!iterator.moveNext()) {
        // We're finished with building the dependency graph.
        graph.seal();
      } else {
        iterator.current.forEachTest(_newTest, testCache, enqueueNextSuite);
      }
    }

    enqueueNextSuite();
  }

  /// Adds a test case to the list of active test cases, and adds its commands
  /// to the dependency graph of commands.
  ///
  /// If the repeat flag is > 1, replicates the test case and its commands,
  /// adding an index field with a distinct value to each of the copies.
  ///
  /// Each copy of the test case depends on the previous copy of the test
  /// case completing, with its first command having a dependency on the last
  /// command of the previous copy of the test case. This dependency is
  /// marked as a "timingDependency", so that it doesn't depend on the previous
  /// test completing successfully, just on it completing.
  void _newTest(TestCase testCase) {
    Node<Command> lastNode;
    for (int i = 0; i < testCase.configuration.repeat; ++i) {
      if (i > 0) {
        testCase = testCase.indexedCopy(i);
      }
      remainingTestCases.add(testCase);
      bool isFirstCommand = true;
      for (var command in testCase.commands) {
        // Make exactly *one* node in the dependency graph for every command.
        // This ensures that we never have two commands c1 and c2 in the graph
        // with "c1 == c2".
        var node = command2node[command];
        if (node == null) {
          var requiredNodes =
              (lastNode != null) ? [lastNode] : <Node<Command>>[];
          node = graph.add(command, requiredNodes,
              timingDependency: isFirstCommand);
          command2node[command] = node;
          command2testCases[command] = <TestCase>[];
        }
        // Keep mapping from command to all testCases that refer to it
        command2testCases[command].add(testCase);

        lastNode = node;
        isFirstCommand = false;
      }
      _onTestCaseAdded(testCase);
    }
  }
}

/*
 * [CommandEnqueuer] will
 *  - change node.state to NodeState.Enqueuing as soon as all dependencies have
 *    a state of NodeState.Successful
 *  - change node.state to NodeState.UnableToRun if one or more dependencies
 *    have a state of NodeState.Failed/NodeState.UnableToRun.
 */
class CommandEnqueuer {
  static const _initStates = const [NodeState.initialized, NodeState.waiting];

  static const _finishedStates = const [
    NodeState.successful,
    NodeState.failed,
    NodeState.unableToRun
  ];

  final Graph<Command> _graph;

  CommandEnqueuer(this._graph) {
    _graph.added.listen(_changeNodeStateIfNecessary);

    _graph.changed.listen((event) {
      if (event.from == NodeState.waiting ||
          event.from == NodeState.processing) {
        if (_finishedStates.contains(event.to)) {
          for (var dependentNode in event.node.neededFor) {
            _changeNodeStateIfNecessary(dependentNode);
          }
        }
      }
    });
  }

  // Called when either a new node was added or if one of it's dependencies
  // changed it's state.
  void _changeNodeStateIfNecessary(Node<Command> node) {
    if (_initStates.contains(node.state)) {
      bool allDependenciesFinished =
          node.dependencies.every((dep) => _finishedStates.contains(dep.state));
      bool anyDependenciesUnsuccessful = node.dependencies.any((dep) =>
          [NodeState.failed, NodeState.unableToRun].contains(dep.state));
      bool allDependenciesSuccessful =
          node.dependencies.every((dep) => dep.state == NodeState.successful);

      var newState = NodeState.waiting;
      if (allDependenciesSuccessful ||
          (allDependenciesFinished && node.timingDependency)) {
        newState = NodeState.enqueuing;
      } else if (anyDependenciesUnsuccessful) {
        newState = NodeState.unableToRun;
      }
      if (node.state != newState) {
        _graph.changeState(node, newState);
      }
    }
  }
}

/*
 * [CommandQueue] will listen for nodes entering the NodeState.ENQUEUING state,
 * queue them up and run them. While nodes are processed they will be in the
 * NodeState.PROCESSING state. After running a command, the node will change
 * to a state of NodeState.Successful or NodeState.Failed.
 *
 * It provides a synchronous stream [completedCommands] which provides the
 * [CommandOutputs] for the finished commands.
 *
 * It provides a [done] future, which will complete once there are no more
 * nodes left in the states Initialized/Waiting/Enqueing/Processing
 * and the [executor] has cleaned up it's resources.
 */
class CommandQueue {
  final Graph<Command> graph;
  final CommandExecutor executor;
  final TestCaseEnqueuer enqueuer;

  final Queue<Command> _runQueue = new Queue<Command>();
  final _commandOutputStream = new StreamController<CommandOutput>(sync: true);
  final _completer = new Completer<Null>();

  int _numProcesses = 0;
  int _maxProcesses;
  int _numBrowserProcesses = 0;
  int _maxBrowserProcesses;
  bool _finishing = false;
  bool _verbose = false;

  CommandQueue(this.graph, this.enqueuer, this.executor, this._maxProcesses,
      this._maxBrowserProcesses, this._verbose) {
    graph.changed.listen((event) {
      if (event.to == NodeState.enqueuing) {
        assert(event.from == NodeState.initialized ||
            event.from == NodeState.waiting);
        graph.changeState(event.node, NodeState.processing);
        var command = event.node.data;
        if (event.node.dependencies.isNotEmpty) {
          _runQueue.addFirst(command);
        } else {
          _runQueue.add(command);
        }
        Timer.run(() => _tryRunNextCommand());
      } else if (event.to == NodeState.unableToRun) {
        _checkDone();
      }
    });

    // We're finished if the graph is sealed and all nodes are in a finished
    // state (Successful, Failed or UnableToRun).
    // So we're calling '_checkDone()' to check whether that condition is met
    // and we can cleanup.
    graph.sealed.listen((event) {
      _checkDone();
    });
  }

  Stream<CommandOutput> get completedCommands => _commandOutputStream.stream;

  Future get done => _completer.future;

  void _tryRunNextCommand() {
    _checkDone();

    if (_numProcesses < _maxProcesses && !_runQueue.isEmpty) {
      Command command = _runQueue.removeFirst();
      var isBrowserCommand = command is BrowserTestCommand;

      if (isBrowserCommand && _numBrowserProcesses == _maxBrowserProcesses) {
        // If there is no free browser runner, put it back into the queue.
        _runQueue.add(command);
        // Don't lose a process.
        new Timer(new Duration(milliseconds: 100), _tryRunNextCommand);
        return;
      }

      _numProcesses++;
      if (isBrowserCommand) _numBrowserProcesses++;

      var node = enqueuer.command2node[command];
      Iterable<TestCase> testCases = enqueuer.command2testCases[command];
      // If a command is part of many TestCases we set the timeout to be
      // the maximum over all [TestCase.timeout]s. At some point, we might
      // eliminate [TestCase.timeout] completely and move it to [Command].
      int timeout = testCases
          .map((TestCase test) => test.timeout)
          .fold(0, (int a, b) => math.max(a, b));

      if (_verbose) {
        print('Running "${command.displayName}" command: $command');
      }

      executor.runCommand(node, command, timeout).then((CommandOutput output) {
        assert(command == output.command);

        _commandOutputStream.add(output);
        if (output.canRunDependendCommands) {
          graph.changeState(node, NodeState.successful);
        } else {
          graph.changeState(node, NodeState.failed);
        }

        _numProcesses--;
        if (isBrowserCommand) _numBrowserProcesses--;

        // Don't lose a process
        Timer.run(() => _tryRunNextCommand());
      });
    }
  }

  void _checkDone() {
    if (!_finishing &&
        _runQueue.isEmpty &&
        _numProcesses == 0 &&
        graph.isSealed &&
        graph.stateCount(NodeState.initialized) == 0 &&
        graph.stateCount(NodeState.waiting) == 0 &&
        graph.stateCount(NodeState.enqueuing) == 0 &&
        graph.stateCount(NodeState.processing) == 0) {
      _finishing = true;
      executor.cleanup().then((_) {
        _completer.complete();
        _commandOutputStream.close();
      });
    }
  }

  void dumpState() {
    print("");
    print("CommandQueue state:");
    print("  Processes: used: $_numProcesses max: $_maxProcesses");
    print("  BrowserProcesses: used: $_numBrowserProcesses "
        "max: $_maxBrowserProcesses");
    print("  Finishing: $_finishing");
    print("  Queue (length = ${_runQueue.length}):");
    for (var command in _runQueue) {
      print("      $command");
    }
  }
}

/*
 * [CommandExecutor] is responsible for executing commands. It will make sure
 * that the following two constraints are satisfied
 *  - [:numberOfProcessesUsed <= maxProcesses:]
 *  - [:numberOfBrowserProcessesUsed <= maxBrowserProcesses:]
 *
 * It provides a [runCommand] method which will complete with a
 * [CommandOutput] object.
 *
 * It provides a [cleanup] method to free all the allocated resources.
 */
abstract class CommandExecutor {
  Future cleanup();
  // TODO(kustermann): The [timeout] parameter should be a property of Command
  Future<CommandOutput> runCommand(
      Node<Command> node, covariant Command command, int timeout);
}

class CommandExecutorImpl implements CommandExecutor {
  final TestConfiguration globalConfiguration;
  final int maxProcesses;
  final int maxBrowserProcesses;
  AdbDevicePool adbDevicePool;

  // For dart2js and analyzer batch processing,
  // we keep a list of batch processes.
  final _batchProcesses = new Map<String, List<BatchRunnerProcess>>();
  // We keep a BrowserTestRunner for every configuration.
  final _browserTestRunners = new Map<TestConfiguration, BrowserTestRunner>();

  bool _finishing = false;

  CommandExecutorImpl(
      this.globalConfiguration, this.maxProcesses, this.maxBrowserProcesses,
      {this.adbDevicePool});

  Future cleanup() {
    assert(!_finishing);
    _finishing = true;

    Future _terminateBatchRunners() {
      var futures = <Future>[];
      for (var runners in _batchProcesses.values) {
        futures.addAll(runners.map((runner) => runner.terminate()));
      }
      return Future.wait(futures);
    }

    Future _terminateBrowserRunners() {
      var futures =
          _browserTestRunners.values.map((runner) => runner.terminate());
      return Future.wait(futures);
    }

    return Future.wait([
      _terminateBatchRunners(),
      _terminateBrowserRunners(),
    ]);
  }

  Future<CommandOutput> runCommand(node, Command command, int timeout) {
    assert(!_finishing);

    Future<CommandOutput> runCommand(int retriesLeft) {
      return _runCommand(command, timeout).then((CommandOutput output) {
        if (retriesLeft > 0 && shouldRetryCommand(output)) {
          DebugLogger.warning("Rerunning Command: ($retriesLeft "
              "attempt(s) remains) [cmd: $command]");
          return runCommand(retriesLeft - 1);
        } else {
          return new Future.value(output);
        }
      });
    }

    return runCommand(command.maxNumRetries);
  }

  Future<CommandOutput> _runCommand(Command command, int timeout) {
    if (command is BrowserTestCommand) {
      return _startBrowserControllerTest(command, timeout);
    } else if (command is VMKernelCompilationCommand) {
      // For now, we always run vm_compile_to_kernel in batch mode.
      var name = command.displayName;
      assert(name == 'vm_compile_to_kernel');
      return _getBatchRunner(name)
          .runCommand(name, command, timeout, command.arguments);
    } else if (command is CompilationCommand &&
        globalConfiguration.batchDart2JS &&
        command.displayName == 'dart2js') {
      return _getBatchRunner("dart2js")
          .runCommand("dart2js", command, timeout, command.arguments);
    } else if (command is AnalysisCommand && globalConfiguration.batch) {
      return _getBatchRunner(command.displayName)
          .runCommand(command.displayName, command, timeout, command.arguments);
    } else if (command is CompilationCommand &&
        (command.displayName == 'dartdevc' ||
            command.displayName == 'dartdevk' ||
            command.displayName == 'fasta') &&
        globalConfiguration.batch) {
      return _getBatchRunner(command.displayName)
          .runCommand(command.displayName, command, timeout, command.arguments);
    } else if (command is ScriptCommand) {
      return command.run();
    } else if (command is AdbPrecompilationCommand ||
        command is AdbDartkCommand) {
      assert(adbDevicePool != null);
      return adbDevicePool.acquireDevice().then((AdbDevice device) async {
        try {
          if (command is AdbPrecompilationCommand) {
            return await _runAdbPrecompilationCommand(device, command, timeout);
          } else {
            return await _runAdbDartkCommand(
                device, command as AdbDartkCommand, timeout);
          }
        } finally {
          await adbDevicePool.releaseDevice(device);
        }
      });
    } else if (command is VmBatchCommand) {
      var name = command.displayName;
      return _getBatchRunner(command.displayName + command.dartFile)
          .runCommand(name, command, timeout, command.arguments);
    } else if (command is CompilationCommand &&
        command.displayName == 'babel') {
      return new RunningProcess(command, timeout,
              configuration: globalConfiguration,
              outputFile: io.File(command.outputFile))
          .run();
    } else if (command is ProcessCommand) {
      return new RunningProcess(command, timeout,
              configuration: globalConfiguration)
          .run();
    } else {
      throw new ArgumentError("Unknown command type ${command.runtimeType}.");
    }
  }

  Future<CommandOutput> _runAdbPrecompilationCommand(
      AdbDevice device, AdbPrecompilationCommand command, int timeout) async {
    var runner = command.precompiledRunnerFilename;
    var processTest = command.processTestFilename;
    var testdir = command.precompiledTestDirectory;
    var arguments = command.arguments;
    var devicedir = DartPrecompiledAdbRuntimeConfiguration.DeviceDir;
    var deviceTestDir = DartPrecompiledAdbRuntimeConfiguration.DeviceTestDir;

    // We copy all the files which the vm precompiler puts into the test
    // directory.
    List<String> files = new io.Directory(testdir)
        .listSync()
        .map((file) => file.path)
        .map((path) => path.substring(path.lastIndexOf('/') + 1))
        .toList();

    var timeoutDuration = new Duration(seconds: timeout);

    var steps = <StepFunction>[];

    steps.add(() => device.runAdbShellCommand(['rm', '-Rf', deviceTestDir]));
    steps.add(() => device.runAdbShellCommand(['mkdir', '-p', deviceTestDir]));
    steps.add(() =>
        device.pushCachedData(runner, '$devicedir/dart_precompiled_runtime'));
    steps.add(
        () => device.pushCachedData(processTest, '$devicedir/process_test'));
    steps.add(() => device.runAdbShellCommand([
          'chmod',
          '777',
          '$devicedir/dart_precompiled_runtime $devicedir/process_test'
        ]));

    for (var file in files) {
      steps.add(() => device
          .runAdbCommand(['push', '$testdir/$file', '$deviceTestDir/$file']));
    }

    steps.add(() => device.runAdbShellCommand(
        [
          '$devicedir/dart_precompiled_runtime',
        ]..addAll(arguments),
        timeout: timeoutDuration));

    var stopwatch = new Stopwatch()..start();
    var writer = new StringBuffer();

    await device.waitForBootCompleted();
    await device.waitForDevice();

    AdbCommandResult result;
    for (var i = 0; i < steps.length; i++) {
      var fun = steps[i];
      var commandStopwatch = new Stopwatch()..start();
      result = await fun();

      writer.writeln("Executing ${result.command}");
      if (result.stdout.length > 0) {
        writer.writeln("Stdout:\n${result.stdout.trim()}");
      }
      if (result.stderr.length > 0) {
        writer.writeln("Stderr:\n${result.stderr.trim()}");
      }
      writer.writeln("ExitCode: ${result.exitCode}");
      writer.writeln("Time: ${commandStopwatch.elapsed}");
      writer.writeln("");

      // If one command fails, we stop processing the others and return
      // immediately.
      if (result.exitCode != 0) break;
    }
    return createCommandOutput(command, result.exitCode, result.timedOut,
        utf8.encode('$writer'), [], stopwatch.elapsed, false);
  }

  Future<CommandOutput> _runAdbDartkCommand(
      AdbDevice device, AdbDartkCommand command, int timeout) async {
    final String buildPath = command.buildPath;
    final String processTest = command.processTestFilename;
    final String hostKernelFile = command.kernelFile;
    final List<String> arguments = command.arguments;
    final String devicedir = DartkAdbRuntimeConfiguration.DeviceDir;
    final String deviceTestDir = DartkAdbRuntimeConfiguration.DeviceTestDir;

    final timeoutDuration = new Duration(seconds: timeout);

    final steps = <StepFunction>[];

    steps.add(() => device.runAdbShellCommand(['rm', '-Rf', deviceTestDir]));
    steps.add(() => device.runAdbShellCommand(['mkdir', '-p', deviceTestDir]));
    steps.add(
        () => device.pushCachedData("${buildPath}/dart", '$devicedir/dart'));
    steps.add(() => device
        .runAdbCommand(['push', hostKernelFile, '$deviceTestDir/out.dill']));

    for (final String lib in command.extraLibraries) {
      final String libname = "lib${lib}.so";
      steps.add(() => device.runAdbCommand(
          ['push', '${buildPath}/$libname', '$deviceTestDir/$libname']));
    }

    steps.add(() => device.runAdbShellCommand(
        [
          'export LD_LIBRARY_PATH=\$LD_LIBRARY_PATH:$deviceTestDir;'
              '$devicedir/dart',
        ]..addAll(arguments),
        timeout: timeoutDuration));

    final stopwatch = new Stopwatch()..start();
    final writer = new StringBuffer();

    await device.waitForBootCompleted();
    await device.waitForDevice();

    AdbCommandResult result;
    for (var i = 0; i < steps.length; i++) {
      var step = steps[i];
      var commandStopwatch = new Stopwatch()..start();
      result = await step();

      writer.writeln("Executing ${result.command}");
      if (result.stdout.length > 0) {
        writer.writeln("Stdout:\n${result.stdout.trim()}");
      }
      if (result.stderr.length > 0) {
        writer.writeln("Stderr:\n${result.stderr.trim()}");
      }
      writer.writeln("ExitCode: ${result.exitCode}");
      writer.writeln("Time: ${commandStopwatch.elapsed}");
      writer.writeln("");

      // If one command fails, we stop processing the others and return
      // immediately.
      if (result.exitCode != 0) break;
    }
    return createCommandOutput(command, result.exitCode, result.timedOut,
        utf8.encode('$writer'), [], stopwatch.elapsed, false);
  }

  BatchRunnerProcess _getBatchRunner(String identifier) {
    // Start batch processes if needed
    var runners = _batchProcesses[identifier];
    if (runners == null) {
      runners = new List<BatchRunnerProcess>(maxProcesses);
      for (int i = 0; i < maxProcesses; i++) {
        runners[i] = new BatchRunnerProcess(useJson: identifier == "fasta");
      }
      _batchProcesses[identifier] = runners;
    }

    for (var runner in runners) {
      if (!runner._currentlyRunning) return runner;
    }
    throw new Exception('Unable to find inactive batch runner.');
  }

  Future<CommandOutput> _startBrowserControllerTest(
      BrowserTestCommand browserCommand, int timeout) {
    var completer = new Completer<CommandOutput>();

    var callback = (BrowserTestOutput output) {
      completer.complete(new BrowserCommandOutput(browserCommand, output));
    };

    var browserTest = new BrowserTest(browserCommand.url, callback, timeout);
    _getBrowserTestRunner(browserCommand.configuration).then((testRunner) {
      testRunner.enqueueTest(browserTest);
    });

    return completer.future;
  }

  Future<BrowserTestRunner> _getBrowserTestRunner(
      TestConfiguration configuration) async {
    if (_browserTestRunners[configuration] == null) {
      var testRunner = new BrowserTestRunner(
          configuration, globalConfiguration.localIP, maxBrowserProcesses);
      if (globalConfiguration.isVerbose) {
        testRunner.logger = DebugLogger.info;
      }
      _browserTestRunners[configuration] = testRunner;
      await testRunner.start();
    }
    return _browserTestRunners[configuration];
  }
}

bool shouldRetryCommand(CommandOutput output) {
  if (!output.successful) {
    List<String> stdout, stderr;

    decodeOutput() {
      if (stdout == null && stderr == null) {
        stdout = decodeUtf8(output.stderr).split("\n");
        stderr = decodeUtf8(output.stderr).split("\n");
      }
    }

    final command = output.command;

    // The dartk batch compiler sometimes runs out of memory. In such a case we
    // will retry running it.
    if (command is VMKernelCompilationCommand) {
      if (output.hasCrashed) {
        bool containsOutOfMemoryMessage(String line) {
          return line.contains('Exhausted heap space, trying to allocat');
        }

        decodeOutput();
        if (stdout.any(containsOutOfMemoryMessage) ||
            stderr.any(containsOutOfMemoryMessage)) {
          return true;
        }
      }
    }

    if (io.Platform.operatingSystem == 'linux') {
      decodeOutput();
      // No matter which command we ran: If we get failures due to the
      // "xvfb-run" issue 7564, try re-running the test.
      bool containsFailureMsg(String line) {
        return line.contains(cannotOpenDisplayMessage) ||
            line.contains(failedToRunCommandMessage);
      }

      if (stdout.any(containsFailureMsg) || stderr.any(containsFailureMsg)) {
        return true;
      }
    }
  }
  return false;
}

/*
 * [TestCaseCompleter] will listen for
 * NodeState.Processing -> NodeState.{Successful,Failed} state changes and
 * will complete a TestCase if it is finished.
 *
 * It provides a stream [finishedTestCases], which will stream all TestCases
 * once they're finished. After all TestCases are done, the stream will be
 * closed.
 */
class TestCaseCompleter {
  static const _completedStates = const [
    NodeState.failed,
    NodeState.successful
  ];

  final Graph<Command> _graph;
  final TestCaseEnqueuer _enqueuer;
  final CommandQueue _commandQueue;

  final Map<Command, CommandOutput> _outputs = {};
  final StreamController<TestCase> _controller = new StreamController();
  bool _closed = false;

  TestCaseCompleter(this._graph, this._enqueuer, this._commandQueue) {
    var finishedRemainingTestCases = false;

    // Store all the command outputs -- they will be delivered synchronously
    // (i.e. before state changes in the graph)
    _commandQueue.completedCommands.listen((CommandOutput output) {
      _outputs[output.command] = output;
    }, onDone: () {
      _completeTestCasesIfPossible(new List.from(_enqueuer.remainingTestCases));
      finishedRemainingTestCases = true;
      assert(_enqueuer.remainingTestCases.isEmpty);
      _checkDone();
    });

    // Listen for NodeState.Processing -> NodeState.{Successful,Failed}
    // changes.
    _graph.changed.listen((event) {
      if (event.from == NodeState.processing && !finishedRemainingTestCases) {
        var command = event.node.data;

        assert(_completedStates.contains(event.to));
        assert(_outputs[command] != null);

        _completeTestCasesIfPossible(_enqueuer.command2testCases[command]);
        _checkDone();
      }
    });

    // Listen also for GraphSealedEvents. If there is not a single node in the
    // graph, we still want to finish after the graph was sealed.
    _graph.sealed.listen((_) {
      if (!_closed && _enqueuer.remainingTestCases.isEmpty) {
        _controller.close();
        _closed = true;
      }
    });
  }

  Stream<TestCase> get finishedTestCases => _controller.stream;

  void _checkDone() {
    if (!_closed && _graph.isSealed && _enqueuer.remainingTestCases.isEmpty) {
      _controller.close();
      _closed = true;
    }
  }

  void _completeTestCasesIfPossible(Iterable<TestCase> testCases) {
    // Update TestCases with command outputs
    for (TestCase test in testCases) {
      for (var icommand in test.commands) {
        var output = _outputs[icommand];
        if (output != null) {
          test.commandOutputs[icommand] = output;
        }
      }
    }

    void completeTestCase(TestCase testCase) {
      if (_enqueuer.remainingTestCases.contains(testCase)) {
        _controller.add(testCase);
        _enqueuer.remainingTestCases.remove(testCase);
      } else {
        DebugLogger.error("${testCase.displayName} would be finished twice");
      }
    }

    for (var testCase in testCases) {
      // Ask the [testCase] if it's done. Note that we assume, that
      // [TestCase.isFinished] will return true if all commands were executed
      // or if a previous one failed.
      if (testCase.isFinished) {
        completeTestCase(testCase);
      }
    }
  }
}

class ProcessQueue {
  TestConfiguration _globalConfiguration;

  Function _allDone;
  final Graph<Command> _graph = new Graph();
  List<EventListener> _eventListener;

  ProcessQueue(
      this._globalConfiguration,
      int maxProcesses,
      int maxBrowserProcesses,
      DateTime startTime,
      List<TestSuite> testSuites,
      this._eventListener,
      this._allDone,
      [bool verbose = false,
      AdbDevicePool adbDevicePool]) {
    void setupForListing(TestCaseEnqueuer testCaseEnqueuer) {
      _graph.sealed.listen((_) {
        var testCases = testCaseEnqueuer.remainingTestCases.toList();
        testCases.sort((a, b) => a.displayName.compareTo(b.displayName));

        print("\nGenerating all matching test cases ....\n");

        for (TestCase testCase in testCases) {
          eventFinishedTestCase(testCase);
          var outcomes = testCase.expectedOutcomes.map((o) => '$o').toList()
            ..sort();
          print("${testCase.displayName}   "
              "Expectations: ${outcomes.join(', ')}   "
              "Configuration: '${testCase.configurationString}'");
        }
        eventAllTestsKnown();
      });
    }

    TestCaseEnqueuer testCaseEnqueuer;
    CommandQueue commandQueue;

    void setupForRunning(TestCaseEnqueuer testCaseEnqueuer) {
      Timer _debugTimer;
      // If we haven't seen a single test finishing during a 10 minute period
      // something is definitely wrong, so we dump the debugging information.
      final debugTimerDuration = const Duration(minutes: 10);

      void cancelDebugTimer() {
        if (_debugTimer != null) {
          _debugTimer.cancel();
        }
      }

      void resetDebugTimer() {
        cancelDebugTimer();
        _debugTimer = new Timer(debugTimerDuration, () {
          print("The debug timer of test.dart expired. Please report this issue"
              " to whesse@ and provide the following information:");
          print("");
          print("Graph is sealed: ${_graph.isSealed}");
          print("");
          _graph.dumpCounts();
          print("");
          var unfinishedNodeStates = [
            NodeState.initialized,
            NodeState.waiting,
            NodeState.enqueuing,
            NodeState.processing
          ];

          for (var nodeState in unfinishedNodeStates) {
            if (_graph.stateCount(nodeState) > 0) {
              print("Commands in state '$nodeState':");
              print("=================================");
              print("");
              for (var node in _graph.nodes) {
                if (node.state == nodeState) {
                  var command = node.data;
                  var testCases = testCaseEnqueuer.command2testCases[command];
                  print("  Command: $command");
                  for (var testCase in testCases) {
                    print("    Enqueued by: ${testCase.configurationString} "
                        "-- ${testCase.displayName}");
                  }
                  print("");
                }
              }
              print("");
              print("");
            }
          }

          if (commandQueue != null) {
            commandQueue.dumpState();
          }
        });
      }

      // When the graph building is finished, notify event listeners.
      _graph.sealed.listen((_) {
        eventAllTestsKnown();
      });

      // Queue commands as they become "runnable"
      new CommandEnqueuer(_graph);

      // CommandExecutor will execute commands
      var executor = new CommandExecutorImpl(
          _globalConfiguration, maxProcesses, maxBrowserProcesses,
          adbDevicePool: adbDevicePool);

      // Run "runnable commands" using [executor] subject to
      // maxProcesses/maxBrowserProcesses constraint
      commandQueue = new CommandQueue(_graph, testCaseEnqueuer, executor,
          maxProcesses, maxBrowserProcesses, verbose);

      // Finish test cases when all commands were run (or some failed)
      var testCaseCompleter =
          new TestCaseCompleter(_graph, testCaseEnqueuer, commandQueue);
      testCaseCompleter.finishedTestCases.listen((TestCase finishedTestCase) {
        resetDebugTimer();

        eventFinishedTestCase(finishedTestCase);
      }, onDone: () {
        // Wait until the commandQueue/exectutor is done (it may need to stop
        // batch runners, browser controllers, ....)
        commandQueue.done.then((_) {
          cancelDebugTimer();
          eventAllTestsDone();
        });
      });

      resetDebugTimer();
    }

    // Build up the dependency graph
    testCaseEnqueuer = new TestCaseEnqueuer(_graph, (TestCase newTestCase) {
      eventTestAdded(newTestCase);
    });

    // Either list or run the tests
    if (_globalConfiguration.listTests) {
      setupForListing(testCaseEnqueuer);
    } else {
      setupForRunning(testCaseEnqueuer);
    }

    // Start enqueing all TestCases
    testCaseEnqueuer.enqueueTestSuites(testSuites);
  }

  void eventFinishedTestCase(TestCase testCase) {
    for (var listener in _eventListener) {
      listener.done(testCase);
    }
  }

  void eventTestAdded(TestCase testCase) {
    for (var listener in _eventListener) {
      listener.testAdded();
    }
  }

  void eventAllTestsKnown() {
    for (var listener in _eventListener) {
      listener.allTestsKnown();
    }
  }

  void eventAllTestsDone() {
    for (var listener in _eventListener) {
      listener.allDone();
    }
    _allDone();
  }
}
