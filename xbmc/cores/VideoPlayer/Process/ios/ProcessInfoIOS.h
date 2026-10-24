/*
 *  Copyright (C) 2005-2018 Team Kodi
 *  This file is part of Kodi - https://kodi.tv
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSES/README.md for more information.
 */

#pragma once

#include "../ProcessInfo.h"

namespace VIDEOPLAYER
{

class CProcessInfoIOS : public CProcessInfo
{
public:
  static CProcessInfo* Create();
  static void Register();

  void SetSwDeinterlacingMethods() override;
  // IsTempoAllowed uses exclusive bounds. Keep audio for the 0.5x–2x UI presets.
  float MinTempoPlatform() override { return 0.49f; }
  float MaxTempoPlatform() override { return 2.01f; }
};

}
