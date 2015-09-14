-- | For a better experience, it is recommended that you import this module
-- unqualified. It overrides some exports of "Opaleye" module. Import as follows:
--
-- @
-- import           Opaleye.SOT
-- import qualified Opaleye as O
-- @
module Opaleye.SOT
 ( -- * Defining a 'Tisch'
   Tisch(..)
 , UnHsR(..)
 , unHsR
 , ToHsI(..)
 , toHsI
 , mkHsI
 , toPgW'
 , toPgW

   -- * Working with 'Tisch'
 , TischTable
 , tisch'
 , tisch
 , HsR
 , HsI
 , PgR
 , PgRN
 , PgW
 , update'
 , update

   -- * Kol
 , Kol
 , kol
 , unKol
 , liftKol
 , liftKol2

   -- * Koln
 , NotNullable
 , Koln
 , koln
 , unKoln
 , matchKoln
 , nul
 , isNull
 , altKoln
 , bindKoln
 , liftKoln
 , liftKoln2

   -- * Executing
 , runUpdate

   -- * Querying
 , leftJoin
 , leftJoinExplicit
 , restrict
 , nullFalse
 , nullTrue
 , no
 , eq
 , lt
 , ou
 , et
   -- * Selecting
 , col
 , cola
   -- * Ordering
 , asc
 , ascnf
 , ascnl
 , desc
 , descnf
 , descnl

   -- * Types
 , Comparable
 , ToColumn(..)
 , Col(..)
 , C(..)
 , T(..)
 , TC(..)
 , RN(..)
 , WD(..)

   -- * Column type details
 , Col_ByName
 , Col_Name
 , Col_PgRType
 , Col_PgRNType
 , Col_PgWType
 , Col_HsRType
 , Col_HsIType
 ) where

import           Opaleye.SOT.Internal
