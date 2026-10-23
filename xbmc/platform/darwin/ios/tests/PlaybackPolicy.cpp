#include "IOSPlaybackPolicy.h"
#include <cassert>
#include <cstdio>
int main()
{
  IOSPlaybackPolicy state;
  assert(!state.IsInterrupted());
  assert(!state.EndInterruption(true, 1));
  state.BeginInterruption(true, 1);
  state.BeginInterruption(false, 1); // repeated notification cannot erase intent
  assert(state.IsInterrupted());
  assert(state.EndInterruption(true, 1));
  assert(!state.EndInterruption(true, 1)); // no duplicate resume
  state.BeginInterruption(false, 2); // already paused by user
  assert(!state.EndInterruption(true, 2));
  state.BeginInterruption(true, 3);
  state.UserCommand(); // pause/stop from PiP, fold controls or remote
  assert(!state.EndInterruption(true, 3));
  state.BeginInterruption(true, 4);
  assert(!state.EndInterruption(false, 4)); // OS denies resumption
  state.BeginInterruption(true, 5);
  assert(!state.EndInterruption(true, 6)); // stream changed during interruption
  puts("PASS: audio-interruption intent, duplicate events, user pause, OS veto, changed stream");
}
