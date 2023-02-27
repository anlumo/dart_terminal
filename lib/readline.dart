// vaguely based on https://github.com/jathak/cli_repl

// Copyright (c) 2018, Jennifer Thakar.
// All rights reserved.

// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//     * Neither the name of the project nor the names of its contributors may be
//       used to endorse or promote products derived from this software without
//       specific prior written permission.

// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
// ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
// ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import 'dart:async';

import 'package:async/async.dart';
import 'package:dartterm/codes.dart';
import 'package:logging/logging.dart';
import 'package:xterm/xterm.dart';

class Readline {
  final Terminal terminal;
  final bool Function(String)? validator;
  String? prompt;
  String? continuation;
  List<String> history = [];
  final int maxHistory;
  final Logger log = Logger('Readline');

  Readline({
    required this.terminal,
    this.validator,
    this.prompt,
    this.continuation,
    this.maxHistory = 10,
  });

  Future<void> run(
    Stream<String> inputStream,
    Future<void> Function(String) handler,
  ) async {
    try {
      final charQueue = this.charQueue = StreamQueue(inputStream);
      while (true) {
        var result = await _readStatementAsync(charQueue);
        if (result == null) {
          terminal.write("\n\r");
          break;
        }
        log.fine('Executing command \'$result\'');
        await handler(result);
      }
    } finally {
      await exit();
    }
  }

  Future<void> exit() async {
    final future = charQueue?.cancel(immediate: true);
    charQueue = null;
    await future;
  }

  Iterable<String> linesToStatements(Iterable<String> lines) sync* {
    String previous = "";
    for (var line in lines) {
      if (previous == "") {
        if (prompt != null) {
          terminal.write(prompt!);
        }
      } else if (continuation != null) {
        terminal.write(continuation!);
      }

      previous += line;
      terminal.write('$line\n\r');
      if (validator == null || validator!(previous)) {
        yield previous;
        previous = "";
      } else {
        previous += '\n';
      }
    }
  }

  StreamQueue<String>? charQueue;

  List<int> buffer = [];
  int cursor = 0;

  setCursor(int c) {
    if (c < 0) {
      c = 0;
    } else if (c > buffer.length) {
      c = buffer.length;
    }
    terminal.moveCursorX(c - cursor);
    cursor = c;
    terminal.notifyListeners();
  }

  int historyIndex = -1;
  String currentSaved = "";

  String previousLines = "";
  bool inContinuation = false;

  Future<String?> _readStatementAsync(StreamQueue<String> eventQueue) async {
    startReadStatement();
    while (true) {
      String input = await eventQueue.next;
      var result = processInput(input);
      if (result != null) return result;
    }
  }

  void startReadStatement() {
    if (prompt != null) {
      terminal.write(prompt!);
    }
    buffer.clear();
    cursor = 0;
    historyIndex = -1;
    currentSaved = "";
    inContinuation = false;
    previousLines = "";
  }

  List<int> yanked = [];

  String? processInput(String inputStr) {
    if (inputStr.length > 2 &&
        inputStr.codeUnitAt(0) == escape &&
        inputStr.codeUnitAt(1) == '['.charCode) {
      switch (inputStr[inputStr.length - 1]) {
        case 'D': // arrow left
          setCursor(cursor - 1);
          break;
        case 'C': // arrow right
          setCursor(cursor + 1);
          break;
        case 'A': // arrow up
          if (historyIndex + 1 < history.length) {
            if (historyIndex == -1) {
              currentSaved = String.fromCharCodes(buffer);
            } else {
              history[historyIndex] = String.fromCharCodes(buffer);
            }
            replaceWith(history[++historyIndex]);
          }
          break;
        case 'B': // arrow down
          if (historyIndex > 0) {
            history[historyIndex] = String.fromCharCodes(buffer);
            replaceWith(history[--historyIndex]);
          } else if (historyIndex == 0) {
            historyIndex--;
            replaceWith(currentSaved);
          }
          break;
        case 'H': // home
          setCursor(0);
          break;
        case 'F': // end
          setCursor(buffer.length);
          break;
        case '~': // custom keycode
          final keyCode =
              int.tryParse(inputStr.substring(2, inputStr.length - 1));
          switch (keyCode) {
            case 3: // forward delete
              if (cursor < buffer.length) {
                delete(1);
              }
              break;
          }
          break;
        default:
          log.warning('Unknown ANSI sequence ${inputStr.substring(1)}');
      }
    } else {
      switch (inputStr) {
        case '\x7f':
          if (cursor > 0) {
            setCursor(cursor - 1);
            delete(1);
          }
          break;
        case '\t':
          terminal.tab();
          break;
        case '\r':
        case '\n':
          String contents = String.fromCharCodes(buffer);
          setCursor(buffer.length);
          input(inputStr.charCode);
          if (history.isEmpty || contents != history.first) {
            history.insert(0, contents);
          }
          while (history.length > maxHistory) {
            history.removeLast();
          }
          if (inputStr.charCode == carriageReturn) {
            terminal.write('\n');
          }
          if (validator == null || validator!(previousLines + contents)) {
            return previousLines + contents;
          }
          previousLines += '$contents\n';
          buffer.clear();
          cursor = 0;
          inContinuation = true;
          if (continuation != null) {
            terminal.write(continuation!);
          }
          break;
        default:
          input(inputStr.charCode);
      }
    }
    return null;
  }

  input(int char) {
    buffer.insert(cursor++, char);
    terminal.write(String.fromCharCodes(buffer.skip(cursor - 1)));
    _moveCursor(-(buffer.length - cursor));
  }

  List<int> delete(int amount) {
    if (amount <= 0) return [];
    int wipeAmount = buffer.length - cursor;
    if (amount > wipeAmount) amount = wipeAmount;
    terminal.write(' ' * wipeAmount);
    _moveCursor(-wipeAmount);
    var result = buffer.sublist(cursor, cursor + amount);
    for (int i = 0; i < amount; i++) {
      buffer.removeAt(cursor);
    }
    terminal.write(String.fromCharCodes(buffer.skip(cursor)));
    _moveCursor(-(buffer.length - cursor));
    return result;
  }

  replaceWith(String text) {
    _moveCursor(-cursor);
    terminal.write(' ' * buffer.length);
    _moveCursor(-buffer.length);
    terminal.write(text);
    buffer.clear();
    buffer.addAll(text.codeUnits);
    cursor = buffer.length;
  }

  _moveCursor(int delta) {
    if (delta != 0) {
      terminal.moveCursorX(delta);
    }
    terminal.notifyListeners();
  }

  clearScreen() {
    terminal.eraseDisplay();
    terminal.setCursor(0, 0);
    if (!inContinuation) {
      if (prompt != null) {
        terminal.write(prompt!);
      }
    } else if (continuation != null) {
      terminal.write(continuation!);
    }
    terminal.write(String.fromCharCodes(buffer));
    _moveCursor(cursor - buffer.length);
  }
}
