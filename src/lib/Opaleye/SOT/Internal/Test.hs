{-# LANGUAGE Arrows #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}

-- | This module contains test and example code. The funny thing is that,
-- as most of this library happens at the type level, these tests run
-- while compiling the library.
--
-- You might learn a thing or two reading the source code.
module Opaleye.SOT.Internal.Test where

import           Control.Arrow
import           Control.Lens
import qualified Data.HList as HL
import           Data.Int
import qualified Database.PostgreSQL.Simple as Pg
import qualified Opaleye as O

import           Opaleye.SOT.Internal

--------------------------------------------------------------------------------
-- Test

data Test = Test Bool (Maybe Bool) Bool (Maybe Int64)

-- | Internal. See "Opaleye.SOT.Internal.Test".
instance Tisch Test where
  type UnTisch Test = Test
  type SchemaName Test = "s"
  type TableName Test = "t"
  type Cols Test = [ 'Col "c1" 'W 'R O.PGBool Bool
                   , 'Col "c2" 'W 'RN O.PGBool Bool
                   , 'Col "c3" 'WN 'R O.PGBool Bool
                   , 'Col "c4" 'WN 'RN O.PGInt8 Int64 ]
  fromRecHs' = \r -> return $ Test
     (r ^. cola (C::C "c1"))
     (r ^. cola (C::C "c2"))
     (r ^. cola (C::C "c3"))
     (r ^. cola (C::C "c4"))
  toRecHs (Test c1 c2 c3 c4) = mkRecHs $ \set_ -> HL.hBuild
     (set_ (C::C "c1") c1)
     (set_ (C::C "c3") c3)
     (set_ (C::C "c2") c2)
     (set_ (C::C "c4") c4)

types :: ()
types = seq x () where
  x :: ( Rec Test '[]
           ~ HL.Tagged (T Test) (HL.Record '[])
       , RecHs Test
           ~ Rec Test (Cols_Hs Test)
       , Cols_Hs Test
           ~ '[HL.Tagged (TC Test "c1") Bool,
               HL.Tagged (TC Test "c2") (Maybe Bool),
               HL.Tagged (TC Test "c3") Bool,
               HL.Tagged (TC Test "c4") (Maybe Int64)]
       , RecHsMay Test
           ~ Rec Test (Cols_HsMay Test)
       , Cols_HsMay Test
           ~ '[HL.Tagged (TC Test "c1") (Maybe Bool),
               HL.Tagged (TC Test "c2") (Maybe (Maybe Bool)),
               HL.Tagged (TC Test "c3") (Maybe Bool),
               HL.Tagged (TC Test "c4") (Maybe (Maybe Int64))]
       ) => ()
  x = ()

-- | Internal. See "Opaleye.SOT.Internal.Test".
instance Comparable Test "c1" Test "c3" O.PGBool 

query1 :: O.Query (RecPgRead Test, RecPgRead Test, RecPgRead Test, RecPgReadNull Test)
query1 = proc () -> do
   t1 <- O.queryTable tisch' -< ()
   t2 <- O.queryTable tisch' -< ()
   O.restrict -< eq
      (view (col (C::C "c1")) t1)
      (view (col (C::C "c1")) t2)
   (t3, t4n) <- O.leftJoin 
      (O.queryTable (tisch (T::T Test)))
      (O.queryTable (tisch (T::T Test)))
      (\(t3, t4) -> eq -- requires instance Comparable Test "c1" Test "c3" O.PGBool 
         (view (col (C::C "c1")) t3)
         (view (col (C::C "c3")) t4)) -< ()
   returnA -< (t1,t2,t3,t4n)

query2 :: O.Query (RecPgRead Test)
query2 = proc () -> do
  (t,_,_,_) <- query1 -< ()
  returnA -< t

outQuery2 :: Pg.Connection -> IO [RecHs Test]
outQuery2 conn = O.runQuery conn query2

query3 :: O.Query (RecPgReadNull Test)
query3 = proc () -> do
  (_,_,_,t) <- query1 -< ()
  returnA -< t

outQuery3 :: Pg.Connection -> IO [Maybe (RecHs Test)]
outQuery3 conn = fmap mayRecHs <$> O.runQuery conn query3

update1 :: Pg.Connection -> IO Int64
update1 conn = O.runUpdate conn tisch' upd fil
  where upd :: RecPgRead Test -> RecPgWrite Test
        upd = over (cola (C::C "c3")) Just
            . over (cola (C::C "c4")) Just
        fil :: Rec Test (Cols_PgRead Test) -> O.Column O.PGBool
        fil = \v -> eqc True (view (col (C::C "c1")) v)

outQuery1 :: Pg.Connection
          -> IO [(RecHs Test, RecHs Test, RecHs Test, Maybe (RecHs Test))]
outQuery1 conn = do
  xs :: [(RecHs Test, RecHs Test, RecHs Test, RecHsMay Test)]
     <- O.runQuery conn query1
  return $ xs <&> \(a,b,c,d) -> (a,b,c, mayRecHs d)
