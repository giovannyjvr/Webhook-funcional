{-# LANGUAGE NoRebindableSyntax #-}
{-# OPTIONS_GHC -fno-warn-missing-import-lists #-}
{-# OPTIONS_GHC -w #-}
module PackageInfo_webhook (
    name,
    version,
    synopsis,
    copyright,
    homepage,
  ) where

import Data.Version (Version(..))
import Prelude

name :: String
name = "webhook"
version :: Version
version = Version [0,1,0,0] []

synopsis :: String
synopsis = "Payment Webhook Service - Programa\231\227o Funcional Insper 2025-1"
copyright :: String
copyright = ""
homepage :: String
homepage = ""
