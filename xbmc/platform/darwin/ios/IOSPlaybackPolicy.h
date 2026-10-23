/* SPDX-License-Identifier: GPL-2.0-or-later */
#pragma once
#include <cstdint>

// Scene deactivation never changes playback intent. Only audio interruptions
// enter this policy; an explicit user command cancels automatic resumption.
class IOSPlaybackPolicy
{
public:
  bool IsInterrupted() const { return m_interrupted; }
  void BeginInterruption(bool wasPlaying, uint64_t session)
  {
    if (m_interrupted) return;
    m_interrupted = true;
    m_resume = wasPlaying;
    m_session = session;
  }
  void UserCommand() { m_resume = false; }
  bool EndInterruption(bool systemAllowsResume, uint64_t session)
  {
    const bool resume = m_interrupted && m_resume && systemAllowsResume && session == m_session;
    m_interrupted = false;
    m_resume = false;
    return resume;
  }
private:
  bool m_interrupted{false};
  bool m_resume{false};
  uint64_t m_session{0};
};
