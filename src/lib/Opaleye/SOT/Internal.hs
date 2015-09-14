{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

-- | This is an internal module. You are not encouraged to use it directly.
module Opaleye.SOT.Internal where

import           Control.Arrow
import           Control.Monad.Reader (MonadReader, ask)
import           Control.Monad.IO.Class (MonadIO, liftIO)
import           Control.Lens
import qualified Control.Exception as Ex
import qualified Data.Aeson
import qualified Data.ByteString
import qualified Data.ByteString.Lazy
import qualified Data.CaseInsensitive
import qualified Data.Text
import qualified Data.Text.Lazy
import qualified Data.Time
import qualified Data.UUID
import           Data.Int
import           Data.Proxy (Proxy(..))
import           Data.HList (Tagged(Tagged, unTagged), HList(HCons, HNil))
import qualified Data.HList as HL
import qualified Data.Profunctor as P
import qualified Data.Profunctor.Product as PP
import qualified Data.Profunctor.Product.Default as PP
import           Data.Singletons
import qualified Data.Promotion.Prelude.List as List (Map)
import qualified Database.PostgreSQL.Simple as Pg
import           GHC.Exts (Constraint)
import           GHC.Float (float2Double)
import qualified GHC.TypeLits as GHC
import qualified Opaleye as O
import qualified Opaleye.Internal.HaskellDB.PrimQuery as OI
import qualified Opaleye.Internal.PGTypes as OI
import qualified Opaleye.Internal.RunQuery as OI
import qualified Opaleye.Internal.Join as OI

-------------------------------------------------------------------------------


-- | Horrible hack to workaround the current represenation for nullable columns.
-- See 'Koln'.
type family NotNullable (x :: *) :: Constraint where
  NotNullable (O.Nullable x) = "NotNullable" ~ "NotNullable: expected `x` but got `Nullable x`"
  NotNullable x = ()

-- | Like @('O.Column' a)@, but guaranteed to be not-'O.Nullable'.
--
-- Build using 'mkKol', view using 'unKol'.
--
-- We do not use @('O.Column' a)@, instead we use @('Kol' a)@ This is where
-- we drift a bit appart from Opaleye, but hopefully not for a long time.
-- See https://github.com/tomjaguarpaw/haskell-opaleye/issues/97
newtype Kol a = UnsafeKol (O.Column a) 
  -- ^ Build safely using 'mkKol'.

mkKol :: NotNullable a => O.Column a -> Kol a
mkKol = UnsafeKol

unKol :: Kol a -> O.Column a
unKol (UnsafeKol ca) = ca

liftKol :: NotNullable b => (O.Column a -> O.Column b) -> (Kol a -> Kol b)
liftKol f = \ka -> mkKol (f (unKol ka))

liftKol2 :: NotNullable c => (O.Column a -> O.Column b -> O.Column c) -> (Kol a -> Kol b -> Kol c)
liftKol2 f = \ka kb -> mkKol (f (unKol ka) (unKol kb))

instance ( Profunctor p, PP.Default p (O.Column a) (O.Column b)
         ) => PP.Default p (Kol a) (O.Column b) where
  def = P.lmap unKol PP.def

instance ( Profunctor p, PP.Default p (O.Column a) (O.Column b), NotNullable b
         ) => PP.Default p (O.Column a) (Kol b) where
  def = P.rmap mkKol PP.def

instance ( Profunctor p, PP.Default p (O.Column a) (O.Column b), NotNullable b
         ) => PP.Default p (Kol a) (Kol b) where
  def = P.dimap unKol mkKol PP.def

instance 
    ( PP.Default O.QueryRunner (O.Column a) b
    ) => PP.Default O.QueryRunner (Kol a) b where
  def = P.lmap unKol PP.def

---

-- | Like @('O.Column' @('O.Nullable' a))@, but @a@ is guaranteed to
-- be not-'O.Nullable'.
--
-- Build safely using 'mkKoln', view using 'unKoln'.
--
-- We do not use 'O.Column ('O.Nullable' a)', but instead we use
-- @('Koln' a)@. This is where we drift a bit appart from Opaleye, but
-- hopefully not for- a long time.
-- See https://github.com/tomjaguarpaw/haskell-opaleye/issues/97
--
-- Think of @('Koln' a)@ as @('Maybe' a)@, where
-- @('Nothing' == 'nul')@ and @('Just' a == 'O.Column' a)@.
newtype Koln a = UnsafeKoln (O.Column (O.Nullable a))
  -- ^ Build safely using 'mkKoln'.

class MkKoln a x where
  mkKoln :: x -> Koln a
instance MkKoln a (Kol a) where
  mkKoln = UnsafeKoln . O.toNullable . unKol
-- | Overlaps.
instance NotNullable a => MkKoln a (O.Column (O.Nullable a)) where
  mkKoln = UnsafeKoln
-- | Overlapped.
instance {-# OVERLAPPABLE #-} NotNullable a => MkKoln a (O.Column a) where
  mkKoln = mkKoln . O.toNullable

unKoln :: Koln a -> O.Column (O.Nullable a)
unKoln (UnsafeKoln cna) = cna

-- | Like 'maybe'. Case analysis for 'Koln'.
matchKoln :: Kol b -> (Kol a -> Kol b) -> Koln a -> Kol b
matchKoln kb0 f kna = UnsafeKol $
  O.matchNullable (unKol kb0) (unKol . f . UnsafeKol) (unKoln kna)

-- | Monadic bind like the one for 'Maybe'.
bindKoln :: Koln a -> (Kol a -> Koln b) -> Koln b
bindKoln kna f = UnsafeKoln $
  O.matchNullable O.null (unKoln . f . UnsafeKol) (unKoln kna)

-- | Billon dollar mistake in French, so as to avoid clashing with 'Prelude.null'.
nul :: NotNullable a => Koln a
nul = UnsafeKoln O.null

liftKoln :: NotNullable b
         => (O.Column (O.Nullable a) -> O.Column (O.Nullable b))
         -> (Koln a -> Koln b)
liftKoln f = \kna -> mkKoln (f (unKoln kna))

liftKoln2 :: NotNullable c
          => (O.Column (O.Nullable a) -> O.Column (O.Nullable b) -> O.Column (O.Nullable c))
          -> (Koln a -> Koln b -> Koln c)
liftKoln2 f = \kna knb -> mkKoln (f (unKoln kna) (unKoln knb))

-- | OVERLAPPABLE.
instance {-# OVERLAPPABLE #-} forall p x a.
    ( P.Profunctor p, NotNullable a
    , PP.Default p x (O.Column (O.Nullable a))
    ) => PP.Default p x (Koln a) where
  def = P.rmap mkKoln (PP.def :: p x (O.Column (O.Nullable a)))
  {-# INLINE def #-}

-- | OVERLAPPABLE.
instance {-# OVERLAPPABLE #-}
    ( P.Profunctor p
    , PP.Default p (O.Column (O.Nullable a)) x
    ) => PP.Default p (Koln a) x where
  def = P.lmap unKoln PP.def
  {-# INLINE def #-}

instance
    ( P.Profunctor p, NotNullable b
    , PP.Default p (O.Column (O.Nullable a)) (O.Column (O.Nullable b))
    ) => PP.Default p (Koln a) (Koln b) where
  def = P.dimap unKoln mkKoln (PP.def :: p (O.Column (O.Nullable a)) (O.Column (O.Nullable b)))
  {-# INLINE def #-}

-- | OVERLAPPABLE.
instance {-# OVERLAPPABLE #-}
    ( O.QueryRunnerColumnDefault pg hs, NotNullable pg
    ) => O.QueryRunnerColumnDefault pg (Maybe hs) where
  queryRunnerColumnDefault = OI.QueryRunnerColumn u (fmap (fmap (fmap Just)) fp)
    where OI.QueryRunnerColumn u fp = O.queryRunnerColumnDefault

-------------------------------------------------------------------------------

-- | Whether to read a plain value or possibly @NULL@.
data RN = R  -- ^ Read plain value.
        | RN -- ^ Possibly read @NULL@.

-- | Whether to write a specific value or possibly @DEFAULT@.
data WD = W  -- ^ Write a specific value.
        | WD -- ^ Possibly write @DEFAULT@.

--------------------------------------------------------------------------------

-- | Column properties.
--
-- This is only used as a promoted datatype expected to have kind
-- @'Col' 'GHC.Symbol' 'WD' 'RN' * *@.
--
-- * @name@: Column name.
--
-- * @wd@: Whether @DEFAULT@ can be written to this column ('WD') or not ('W').
--
-- * @rn@: Whether @NULL@ might be read from this column ('RN') or not ('R').
--
-- * @pgType@: Type of the column value used in Opaleye queries
--   (e.g., 'O.PGText', 'O.PGInt2').
--
-- * @hsType@: Type of the column value used in Haskell outside Opaleye
--   queries. Hint: don't use something like @'Maybe' 'Bool'@ here if you
--   want to indicate that this is an optional 'Bool' column. Instead, use
--   'Int' here and 'RN' in the @rn@ field.
data Col name wd rn pgType hsType
   = Col name wd rn pgType hsType

--

type family Col_Name (col :: Col GHC.Symbol WD RN * *) :: GHC.Symbol where
  Col_Name ('Col n w r p h) = n
data Col_NameSym0 (col :: TyFun (Col GHC.Symbol WD RN * *) GHC.Symbol)
type instance Apply Col_NameSym0 col = Col_Name col

type family Col_PgRType (col :: Col GHC.Symbol WD RN * *) :: * where
  Col_PgRType ('Col n w 'R  p h) = Kol p
  Col_PgRType ('Col n w 'RN p h) = Koln p

type family Col_PgRNType (col :: Col GHC.Symbol WD RN * *) :: * where
  Col_PgRNType ('Col n w r p h) = Koln p

type family Col_PgWType (col :: Col GHC.Symbol WD RN * *) :: * where
  Col_PgWType ('Col n 'W  r p h) = Col_PgRType ('Col n 'W r p h)
  Col_PgWType ('Col n 'WD r p h) = Maybe (Col_PgRType ('Col n 'WD r p h))

type family Col_HsRType (col :: Col GHC.Symbol WD RN * *) :: * where
  Col_HsRType ('Col n w 'R  p h) = h
  Col_HsRType ('Col n w 'RN p h) = Maybe h

type family Col_HsIType (col :: Col GHC.Symbol WD RN * *) :: * where
  Col_HsIType ('Col n 'W  r p h) = Col_HsRType ('Col n 'W r p h)
  Col_HsIType ('Col n 'WD r p h) = Maybe (Col_HsRType ('Col n 'WD r p h))

---

-- | Lookup a column in @'Tisch' t@ by its name.
type Col_ByName (t :: *) (c :: GHC.Symbol) = Col_ByName' c (Cols t)
type family Col_ByName' (name :: GHC.Symbol) (cols :: [Col GHC.Symbol WD RN * *]) :: Col GHC.Symbol WD RN * * where
  Col_ByName' n ('Col n  w r p h ': xs) = 'Col n w r p h
  Col_ByName' n ('Col n' w r p h ': xs) = Col_ByName' n xs

type HasColName (t :: *) (c :: GHC.Symbol) =  HasColName' c (Cols t)
type family HasColName' (name :: GHC.Symbol) (cols :: [Col GHC.Symbol WD RN * *]) :: Constraint where
  HasColName' n ('Col n  w r p h ': xs) = ()
  HasColName' n ('Col n' w r p h ': xs) = HasColName' n xs

---

-- | Payload for @('HsR' t)@
type Cols_HsR (t :: *) = List.Map (Col_HsRFieldSym1 t) (Cols t)
type Col_HsRField (t :: *) (col :: Col GHC.Symbol WD RN * *)
  = Tagged (TC t (Col_Name col)) (Col_HsRType col)
data Col_HsRFieldSym1 (t :: *) (col :: TyFun (Col GHC.Symbol WD RN * *) *)
type instance Apply (Col_HsRFieldSym1 t) col = Col_HsRField t col

-- | Payload for @('HsI' t)@
type Cols_HsI (t :: *) = List.Map (Col_HsIFieldSym1 t) (Cols t)
type Col_HsIField (t :: *) (col :: Col GHC.Symbol WD RN * *)
  = Tagged (TC t (Col_Name col)) (Col_HsIType col)
data Col_HsIFieldSym1 (t :: *) (col :: TyFun (Col GHC.Symbol WD RN * *) *)
type instance Apply (Col_HsIFieldSym1 t) col = Col_HsIField t col

-- | Payload for @('PgR' t)@
type Cols_PgR (t :: *) = List.Map (Col_PgRSym1 t) (Cols t)
type family Col_PgR (t :: *) (col :: Col GHC.Symbol WD RN * *) :: * where
  Col_PgR t ('Col n w r p h) = Tagged (TC t n) (Col_PgRType ('Col n w r p h))
data Col_PgRSym1 (t :: *) (col :: TyFun (Col GHC.Symbol WD RN * *) *)
type instance Apply (Col_PgRSym1 t) col = Col_PgR t col

-- | Payload for @('PgRN' t)@
type Cols_PgRN (t :: *) = List.Map (Col_PgRNSym1 t) (Cols t)
type family Col_PgRN (t :: *) (col :: Col GHC.Symbol WD RN * *) :: * where
  Col_PgRN t ('Col n w r p h) = Tagged (TC t n) (Col_PgRNType ('Col n w r p h))
data Col_PgRNSym1 (t :: *) (col :: TyFun (Col GHC.Symbol WD RN * *) *)
type instance Apply (Col_PgRNSym1 t) col = Col_PgRN t col

-- | Type of the 'HL.Record' columns when inserting or updating a row. Also,
-- payload for @('PgI' t)@.
type Cols_PgW (t :: *) = List.Map (Col_PgWSym1 t) (Cols t)
type family Col_PgW (t :: *) (col :: Col GHC.Symbol WD RN * *) :: * where
  Col_PgW t ('Col n w r p h) = Tagged (TC t n) (Col_PgWType ('Col n w r p h))
data Col_PgWSym1 (t :: *) (col :: TyFun (Col GHC.Symbol WD RN * *) *)
type instance Apply (Col_PgWSym1 t) col = Col_PgW t col

--------------------------------------------------------------------------------

-- | Tag to be used alone or with 'Tagged' for uniquely identifying a specific
-- table in a specific schema.
data Tisch t => T (t :: *) = T

-- | Tag to be used alone or with 'Tagged' for uniquely identifying a specific
-- column in a specific table in a specific schema.
data Tisch t => TC (t :: *) (c :: GHC.Symbol) = TC

-- | Tag to be used alone or with 'Tagged' for uniquely identifying a specific
-- column in an unknown table.
data C (c :: GHC.Symbol) = C

--------------------------------------------------------------------------------

-- | All the representation of @t@ used within @opaleye-sot@ are @('Rec' t)@.
type Rec (t :: *) xs = Tagged (T t) (HL.Record xs)

-- | Expected output type for 'O.runQuery' on a @('PgR' t)@.
--
-- Important: If you are expecting a @('PgR' t)@ on the right side
-- of a 'O.leftJoin', you will need to use @('Maybe' ('PgR' t))@.
--
-- Mnemonic: Haskell Read.
type HsR (t :: *) = Rec t (Cols_HsR t)

-- | Output type of 'toHsI', used when inserting a new row to the table.
--
-- This type is used internally as an intermediate representation between
-- your own Haskell representation for a to-be-inserted @t@ and @('PgW' t)@.
--
-- Mnemonic: Haskell Insert.
type HsI (t :: *) = Rec t (Cols_HsI t)

-- | Output type of @'O.queryTable' ('tisch' t)@.
--
-- Mnemonic: PostGresql Read.
type PgR (t :: *) = Rec t (Cols_PgR t)

-- | Like @('PgRN' t)@ but every field is 'Koln', as in the
-- output type of the right hand side of a 'O.leftJoin' with @'(tisch' t)@.
--
-- Mnemonic: PostGresql Read Nulls.
type PgRN (t :: *) = Rec t (Cols_PgRN t)

-- | Representation of @('ToHsI' t)@ as 'Kols'. To be used when
-- writing to the database.
--
-- Mnemonic: PostGresql Write.
type PgW (t :: *) = Rec t (Cols_PgW t)

--------------------------------------------------------------------------------

-- | All these constraints need to be satisfied by tools that work with 'Tisch'.
-- It's easier to just write all the constraints once here and make 'ITisch' a
-- superclass of 'Tisch'. Moreover, they enforce some sanity constraints on our
-- 'Tisch' so that we can get early compile time errors.
type ITisch t
  = ( GHC.KnownSymbol (SchemaName t)
    , GHC.KnownSymbol (TableName t)
    , HDistributeProxy (Cols t)
    , HL.HMapAux HList (HCol_Props t) (List.Map ProxySym0 (Cols t)) (Cols_Props t)
    , HL.HMapAux HList HL.TaggedFn (HL.RecordValuesR (Cols_HsR t)) (Cols_HsR t)
    , HL.HMapAux HList HL.TaggedFn (HL.RecordValuesR (Cols_PgW t)) (Cols_PgW t)
    , HL.HMapAux HList HPgWfromHsIField (HL.RecordValuesR (Cols_HsI t)) (HL.RecordValuesR (Cols_PgW t))
    , HL.HMapAux HList HPgWfromPgRField (HL.RecordValuesR (Cols_PgR t)) (HL.RecordValuesR (Cols_PgW t))
    , HL.HRLabelSet (Cols_HsR t)
    , HL.HRLabelSet (Cols_HsI t)
    , HL.HRLabelSet (Cols_PgR t)
    , HL.HRLabelSet (Cols_PgRN t)
    , HL.HRLabelSet (Cols_PgW t)
    , HL.RecordValues (Cols_HsR t)
    , HL.RecordValues (Cols_HsI t)
    , HL.RecordValues (Cols_PgR t)
    , HL.RecordValues (Cols_PgRN t)
    , HL.RecordValues (Cols_PgW t)
    , HL.SameLength (HL.RecordValuesR (Cols_HsI t)) (HL.RecordValuesR (Cols_PgW t))
    , HL.SameLength (HL.RecordValuesR (Cols_PgR t)) (HL.RecordValuesR (Cols_PgW t))
    , HL.SameLength (Cols_Props t) (List.Map ProxySym0 (Cols t))
    , ProductProfunctorAdaptor O.TableProperties (HL.Record (Cols_Props t)) (HL.Record (Cols_PgW t)) (HL.Record (Cols_PgR t))
    )

-- | Tisch means table in german.
--
-- An instance of this class can uniquely describe a PostgreSQL table and
-- how to convert back and forth between it and its Haskell representation
-- used when writing Opaleye queries.
--
-- The @t@ type is only used as a tag for the purposes of uniquely identifying
-- this 'Tisch'. We recommend that for each 'Tisch' you define a tag with a
-- single constructor like the following:
--
-- @
-- -- | Tag for the users table (just an example).
-- data TUser = TUser
-- @
--
-- Why? Because that way the 'TUser' type can be used as the 'Tisch' tag,
-- and the @TUser@ term constructor can be used as a type proxy for tools such
-- as 'tisch' or 'unHsR'.
class ITisch t => Tisch (t :: *) where
  -- | PostgreSQL schema name where to find the table (defaults to @"public"@,
  -- PostgreSQL's default schema name).
  type SchemaName t :: GHC.Symbol
  type SchemaName t = "public"

  -- | Table name.
  type TableName t :: GHC.Symbol

  -- | Columns in this table. See the documentation for 'Col'.
  type Cols t :: [Col GHC.Symbol WD RN * *]

--------------------------------------------------------------------------------

-- | Convert an Opaleye-compatible Haskell representation of @a@ to @a@ when
-- /reading/ from the database.
--
-- Notice that you are not required to provide instances of this class if working
-- with @'HsR' t@ is sufficient for you, or if you already have a function
-- @('HsR' t -> a)@ at hand.
class Tisch t => UnHsR t (a :: *) where
  -- | Convert an Opaleye-compatible Haskell representation of @a@ to @a@.
  --
  -- For your convenience, you are encouraged to use 'cola', but you may also use
  -- other tools from "Data.HList.Record" as you see fit:
  --
  -- @
  -- 'unHsR'' r = Person (r '^.' 'cola' ('C' :: 'C' "name"))
  --                   (r '^.' 'cola' ('C' :: 'C' "age"))
  -- @
  --
  -- Hint: If the type checker is having trouble inferring @('HsR' t)@,
  -- consider using 'unHsR' instead.
  unHsR' :: HsR t -> Either Ex.SomeException a

-- | Like 'unHsR'', except it takes @t@ explicitely for the times when
-- it can't be inferred.
unHsR :: UnHsR t a => t -> HsR t -> Either Ex.SomeException a
unHsR _ = unHsR'
{-# INLINE unHsR #-}

--------------------------------------------------------------------------------

-- | Build a @('HsR' t)@ representation for @a@ for /inserting/ it to the database.
--
-- Notice that you are not required to provide instances of this class if working
-- with @'HsI' t@ is sufficient for you, or if you already have a function
-- @(a -> 'HsI' t)@ at hand.
class Tisch t => ToHsI t (a :: *) where
  -- | Convert an @a@ to an Opaleye-compatible Haskell representation
  -- to be used when inserting a new row to this table.
  --
  -- For your convenience, you may use 'mkHsI' together with 'HL.hBuild' to build
  -- 'toHsI':
  --
  -- @
  -- 'toHsI' (Person name age) = 'mkHsI' $ \\set_ -> 'HL.hBuild'
  --     (set_ ('C' :: 'C' "name") name)
  --     (set_ ('C' :: 'C' "age") age)
  -- @
  --
  -- You may also use other tools from "Data.HList.Record" as you see fit.
  --
  -- Hint: If the type checker is having trouble inferring @('HsI' t)@,
  -- consider using 'toHsI' instead. Nevertheless, it is more
  -- likely that you use 'toPgW' directly, which skips the 'HsI' intermediate
  -- representation altogether.
  toHsI' :: a -> HsI t

-- | Like 'toHsI'', except it takes @t@ explicitely for the times when
-- it can't be inferred.
toHsI :: ToHsI t a => t -> a -> HsI t
toHsI _ = toHsI'
{-# INLINE toHsI #-}

-- | Convenience intended to be used within 'toHsI'', together with 'HL.hBuild'.

-- TODO: see if it is posisble to pack 'hsi' and 'HL.hBuild' into
-- a single thing.
mkHsI
  :: forall t xs
  .  (Tisch t, HL.HRearrange (HL.LabelsOf (Cols_HsI t)) xs (Cols_HsI t))
  => ((forall c a. (C c -> a -> Tagged (TC t c) a)) -> HList xs)
  -> HsI t -- ^
mkHsI k = Tagged
      $ HL.Record
      $ HL.hRearrange2 (Proxy :: Proxy (HL.LabelsOf (Cols_HsI t)))
      $ k (const Tagged)
{-# INLINE mkHsI #-}

--------------------------------------------------------------------------------

-- | Use with 'HL.ApplyAB' to apply convert a field in a
-- @('HList' ('Cols_HsI' t)@) to a field in a @('HList' ('Cols_PgW' t))@.
data HPgWfromHsIField = HPgWfromHsIField
instance HL.ApplyAB HPgWfromHsIField x x where
  applyAB _ = id
instance ToColumn pg hs => HL.ApplyAB HPgWfromHsIField hs (Kol pg) where
  applyAB _ = val
instance ToColumn pg hs => HL.ApplyAB HPgWfromHsIField (Maybe hs) (Maybe (Kol pg)) where
  applyAB _ = fmap val
instance ToColumn pg hs => HL.ApplyAB HPgWfromHsIField (Maybe hs) (Koln pg) where
  applyAB _ = maybe nul valn
instance ToColumn pg hs => HL.ApplyAB HPgWfromHsIField (Maybe (Maybe hs)) (Maybe (Koln pg)) where
  applyAB _ = fmap (maybe nul valn)

-- | You'll need to use this function to convert a 'HsI' to a 'PgW' when using 'O.runInsert'.
toPgW_fromHsI' :: Tisch t => HsI t -> PgW t
toPgW_fromHsI' = Tagged . HL.hMapTaggedFn . HL.hMapL HPgWfromHsIField . HL.recordValues . unTagged
{-# INLINE toPgW_fromHsI' #-}

-- | Like 'toPgW_fromHsI'', but takes an explicit @t@.
toPgW_fromHsI :: Tisch t => t -> HsI t -> PgW t
toPgW_fromHsI _ = toPgW_fromHsI'
{-# INLINE toPgW_fromHsI #-}

--------------------------------------------------------------------------------

-- | Convert a custom Haskell type to a representation appropiate for /inserting/
-- it as a new row.
toPgW' :: ToHsI t a => a -> PgW t
toPgW' = toPgW_fromHsI' . toHsI'
{-# INLINE toPgW' #-}

-- | Like 'toPgW'', but takes an explicitl @t@.
toPgW :: ToHsI t a => t -> a -> PgW t
toPgW _ = toPgW'
{-# INLINE toPgW #-}

--------------------------------------------------------------------------------

-- | Use with 'HL.ApplyAB' to apply convert a field in a
-- @('HList' ('Cols_PgR' t)@) to a field in a @('HList' ('Cols_PgW' t))@.
data HPgWfromPgRField = HPgWfromPgRField
instance HL.ApplyAB HPgWfromPgRField x x where
  applyAB _ = id
instance NotNullable pg => HL.ApplyAB HPgWfromPgRField (Kol pg) (Maybe (Kol pg)) where
  applyAB _ = Just
instance NotNullable pg => HL.ApplyAB HPgWfromPgRField (Koln pg) (Maybe (Koln pg)) where
  applyAB _ = Just

-- | Convert a @('PgR' t)@ resulting from a 'O.queryTable'-like operation
-- to a @('PgW' t)@ that can be used in a 'runUpdate'-like operation.
update' :: Tisch t => PgR t -> PgW t
update' = Tagged . HL.hMapTaggedFn . HL.hMapL HPgWfromPgRField . HL.recordValues . unTagged
{-# INLINE update' #-}

-- | Like 'update'', but takes an explicit @t@ for when it can't be inferred.
update :: Tisch t => t -> PgR t -> PgW t
update _ = update'
{-# INLINE update #-}

--------------------------------------------------------------------------------

-- | Column properties: Write (no default), Read (not nullable).
colProps_wr :: NotNullable a => String -> O.TableProperties (Kol a) (Kol a)
colProps_wr = P.dimap unKol mkKol . O.required

-- | Column properties: Write (no default), Read (nullable).
colProps_wrn :: NotNullable a => String -> O.TableProperties (Koln a) (Koln a)
colProps_wrn = P.dimap (unsafeUnNullableColumn . unKoln) mkKoln . O.required

-- | Column properties: Write (optional default), Read (not nullable).
colProps_wdr :: NotNullable a => String -> O.TableProperties (Maybe (Kol a)) (Kol a)
colProps_wdr = P.dimap (fmap unKol) mkKol . O.optional

-- | Column properties: Write (optional default), Read (nullable).
colProps_wdrn :: NotNullable a => String -> O.TableProperties (Maybe (Koln a)) (Koln a)
colProps_wdrn = P.dimap (fmap unKoln) mkKoln . O.optional

--------------------------------------------------------------------------------

-- | 'O.TableProperties' for all the columns in 'Tisch' @t@.
type Cols_Props (t :: *) = List.Map (Col_PropsSym1 t) (Cols t)

-- | 'O.TableProperties' for a single column in 'Tisch' @t@.
type Col_Props (t :: *) (col :: Col GHC.Symbol WD RN * *)
  = O.TableProperties (Col_PgW t col) (Col_PgR t col)
data Col_PropsSym1 (t :: *) (col :: TyFun (Col GHC.Symbol WD RN * *) *)
type instance Apply (Col_PropsSym1 t) col = Col_Props t col
data Col_PropsSym0 (col :: TyFun t (TyFun (Col GHC.Symbol WD RN * *) * -> *))
type instance Apply Col_PropsSym0 t = Col_PropsSym1 t

class ICol_Props (col :: Col GHC.Symbol WD RN * *) where
  colProps :: Tisch t => Proxy t -> Proxy col -> Col_Props t col

-- | 'colProps' is equivalent 'colProps_wr'.
instance forall n p h. (GHC.KnownSymbol n, NotNullable p) => ICol_Props ('Col n 'W 'R p h) where
  colProps _ = \_ -> ppaUnTagged (colProps_wr (GHC.symbolVal (Proxy :: Proxy n)))
  {-# INLINE colProps #-}
-- | 'colProps' is equivalent 'colProps_wrn'.
instance forall n p h. (GHC.KnownSymbol n, NotNullable p) => ICol_Props ('Col n 'W 'RN p h) where
  colProps _ = \_ -> ppaUnTagged (colProps_wrn (GHC.symbolVal (Proxy :: Proxy n)))
  {-# INLINE colProps #-}
-- | 'colProps' is equivalent 'colProps_wdr'.
instance forall n p h. (GHC.KnownSymbol n, NotNullable p) => ICol_Props ('Col n 'WD 'R p h) where
  colProps _ = \_ -> ppaUnTagged (colProps_wdr (GHC.symbolVal (Proxy :: Proxy n)))
  {-# INLINE colProps #-}
-- | 'colProps' is equivalent 'colProps_wdrn'.
instance forall n p h. (GHC.KnownSymbol n, NotNullable p) => ICol_Props ('Col n 'WD 'RN p h) where
  colProps _ = \_ -> ppaUnTagged (colProps_wdrn (GHC.symbolVal (Proxy :: Proxy n)))
  {-# INLINE colProps #-}

-- | Use with 'HL.ApplyAB' to apply 'colProps' to each element of an 'HList'.
data HCol_Props (t :: *) = HCol_Props

instance forall t (col :: Col GHC.Symbol WD RN * *) pcol out n w r p h
  . ( Tisch t
    , GHC.KnownSymbol n
    , ICol_Props col
    , pcol ~ Proxy col
    , col ~ 'Col n w r p h
    , out ~ Col_Props t col
    ) => HL.ApplyAB (HCol_Props t) pcol out
    where
      applyAB _ = colProps (Proxy :: Proxy t)
      {-# INLINE applyAB #-}

--------------------------------------------------------------------------------

-- | Opaleye 'O.Table' for a 'Tisch'.
type TischTable (t :: *) = O.Table (PgW t) (PgR t)

-- | Build the Opaleye 'O.Table' for a 'Tisch'.
tisch' :: Tisch t => TischTable t
tisch' = go where -- to hide the "forall" from the haddocks
   go :: forall t. Tisch t => TischTable t
   go = O.TableWithSchema
     (GHC.symbolVal (Proxy :: Proxy (SchemaName t)))
     (GHC.symbolVal (Proxy :: Proxy (TableName t)))
     (ppaUnTagged $ ppa $ HL.Record
        (HL.hMapL (HCol_Props :: HCol_Props t)
        (hDistributeProxy (Proxy :: Proxy (Cols t)))))
   {-# INLINE go #-}
{-# INLINE tisch' #-}

-- | Like 'tisch'', but takes @t@ explicitly to help the compiler when it
-- can't infer @t@.
tisch :: Tisch t => t -> TischTable t
tisch _ = tisch'

--------------------------------------------------------------------------------
-- RunXXX functions

-- | Like Opaleye's 'O.runUpdate', but the predicate is expected to
-- return a @('GetKol' w 'O.PGBool')@.
runUpdate
  :: (MonadReader Pg.Connection m, MonadIO m, GetKol gkb O.PGBool)
  => O.Table pgw pgr -> (pgr -> pgw) -> (pgr -> gkb) -> m Int64 -- ^
runUpdate t upd fil = ask >>= \conn -> liftIO $ do
   O.runUpdate conn t upd (unKol . getKol . fil)

--------------------------------------------------------------------------------

-- | Provide 'Comparable' instances for every two columns that you want to be
-- able to compare (e.g., using 'eq').
class ( Tisch t1, Tisch t2, HasColName t1 c1, HasColName t2 c2
      ) => Comparable (t1 :: *) (c1 :: GHC.Symbol) (t2 :: *) (c2 :: GHC.Symbol) where
  _ComparableL :: Iso (Tagged (TC t1 c1) a) (Tagged (TC t2 c2) a) a a
  _ComparableL = _Wrapped
  _ComparableR :: Iso (Tagged (TC t2 c2) a) (Tagged (TC t1 c1) a) a a
  _ComparableR = _Wrapped

-- | Trivial. Same table, same column, same value.
instance (Tisch t, HasColName t c) => Comparable t c t c

--------------------------------------------------------------------------------

-- | Convert a constant Haskell value to a 'Kol'.
val :: forall pg hs. ToColumn pg hs => hs -> Kol pg
val = mkKol . toColumn
{-# INLINE val #-}

-- | Convert a constant Haskell value to a 'Koln'.
valn :: forall pg hs. ToColumn pg hs => hs -> Koln pg
valn = mkKoln . (val :: hs -> Kol pg)
{-# INLINE valn #-}

-- | Convert a Haskell value to a PostgreSQL 'O.Column' value.
-- Think of 'O.pgString', 'O.pgInt4', 'O.pgStrictText', etc.
--
-- You probably won't ever need to call 'toColumn' explicity, yet you need to
-- provide an instance for every Haskell type you plan to convert to its
-- PostgreSQL representation. Quite likely, you will be using 'toPgTC' though.
--
-- A a default implementation of 'toColumn' is available for 'Wrapped' types
class NotNullable pg => ToColumn (pg :: *) (hs :: *) where
  toColumn :: hs -> O.Column pg
  default toColumn :: (Wrapped hs, ToColumn pg (Unwrapped hs)) => hs -> O.Column pg
  toColumn = toColumn . view _Wrapped'
  {-# INLINE toColumn #-}

instance ToColumn pg hs => ToColumn pg (Tagged t hs)
instance ToColumn O.PGText [Char] where toColumn = O.pgString
instance ToColumn O.PGText Char where toColumn = toColumn . (:[])
instance ToColumn O.PGBool Bool where toColumn = O.pgBool
-- | Note: Portability wise, it's a /terrible/ idea to have an 'Int' instance instead.
-- Use 'Int32', 'Int64', etc. explicitely.
instance ToColumn O.PGInt4 Int32 where toColumn = O.pgInt4 . fromIntegral
-- | Note: Portability wise, it's a /terrible/ idea to have an 'Int' instance instead.
-- Use 'Int32', 'Int64', etc. explicitely.
instance ToColumn O.PGInt8 Int64 where toColumn = O.pgInt8
instance ToColumn O.PGFloat4 Float where toColumn = pgFloat4
instance ToColumn O.PGFloat8 Float where toColumn = pgFloat8
instance ToColumn O.PGFloat8 Double where toColumn = O.pgDouble
instance ToColumn O.PGText Data.Text.Text where toColumn = O.pgStrictText
instance ToColumn O.PGText Data.Text.Lazy.Text where toColumn = O.pgLazyText
instance ToColumn O.PGBytea Data.ByteString.ByteString where toColumn = O.pgStrictByteString
instance ToColumn O.PGBytea Data.ByteString.Lazy.ByteString where toColumn = O.pgLazyByteString
instance ToColumn O.PGTimestamptz Data.Time.UTCTime where toColumn = O.pgUTCTime
instance ToColumn O.PGTimestamp Data.Time.LocalTime where toColumn = O.pgLocalTime
instance ToColumn O.PGTime Data.Time.TimeOfDay where toColumn = O.pgTimeOfDay
instance ToColumn O.PGDate Data.Time.Day where toColumn = O.pgDay
instance ToColumn O.PGUuid Data.UUID.UUID where toColumn = O.pgUUID
instance ToColumn O.PGCitext (Data.CaseInsensitive.CI Data.Text.Text) where toColumn = O.pgCiStrictText
instance ToColumn O.PGCitext (Data.CaseInsensitive.CI Data.Text.Lazy.Text) where toColumn = O.pgCiLazyText
instance Data.Aeson.ToJSON hs => ToColumn O.PGJson hs where toColumn = O.pgLazyJSON . Data.Aeson.encode
instance Data.Aeson.ToJSON hs => ToColumn O.PGJsonb hs where toColumn = O.pgLazyJSONB . Data.Aeson.encode

--------------------------------------------------------------------------------

-- | Lens to the value of a column.
--
-- Mnemonic: the COLumn.
col :: HL.HLensCxt (TC t c) HL.Record xs xs' a a'
    => C c
    -> Lens (Rec t xs) (Rec t xs') (Tagged (TC t c) a) (Tagged (TC t c) a')
col prx = cola prx . _Unwrapped
{-# INLINE col #-}

-- | Lens to the value of a column without the 'TC' tag.
--
-- Most of the time you'll want to use 'col' instead, but this might be more useful
-- when trying to change the type of @a@ during an update, or when implementing
-- 'unHsR'.
--
-- Mnemonic: The COLumn's A.
cola :: HL.HLensCxt (TC t c) HL.Record xs xs' a a'
     => C c
     -> Lens (Rec t xs) (Rec t xs') a a'
cola = go where -- just to hide the "forall" from the haddocks
  go
    :: forall t c xs xs' a a'. HL.HLensCxt (TC t c) HL.Record xs xs' a a'
    => C c -> Lens (Rec t xs) (Rec t xs') a a'
  go = \_ -> _Wrapped . HL.hLens (HL.Label :: HL.Label (TC t c))
  {-# INLINE go #-}
{-# INLINE cola #-}


-- | Like 'cola', but just a 'Setter' that takes constant 'ToColumn' values.
--
-- Mnemonic: the COLumn's A constant Value.
colav
  :: (HL.HLensCxt (TC t c) HL.Record xs xs' (Kol a) (Kol a'), ToColumn a' hs)
  => C c -> Setter (Rec t xs) (Rec t xs') (Kol a) hs
colav c = cola c . sets (\f ca -> val (f ca))
{-# INLINE colav #-}

--------------------------------------------------------------------------------
-- Unary operations on columns

-- | Polymorphic Opaleye's 'O.not'. See 'eq' for the type of arguments this
-- function can take.
--
-- “no” is “not” in English, Spanish, and Italian, and it is a great name
-- because it doesn't clash with 'Prelude.not'.
no :: Fk1 O.PGBool O.PGBool (Kol O.PGBool) (Kol O.PGBool) a b => a -> b
no = fk1 (liftKol O.not)

--------------------------------------------------------------------------------
-- Binary operations on columns

-- | Polymorphic Opaleye's @('O..==')@.
--
-- @
-- 'eq' :: 'Kol' x -> 'Kol' x -> 'Kol' 'O.PGBool'
-- 'eq' :: 'Kol' x -> 'Koln' x -> 'Koln' 'O.PGBool'
-- 'eq' :: 'Kol' x -> 'Tagged' t ('Kol' x) -> 'Kol' 'O.PGBool'
-- 'eq' :: 'Kol' x -> 'Tagged' t ('Koln' x) -> 'Koln' 'O.PGBool'
-- 'eq' :: 'Koln' x -> 'Kol' x -> 'Koln' 'O.PGBool'
-- 'eq' :: 'Koln' x -> 'Koln' x -> 'Koln' 'O.PGBool'
-- 'eq' :: 'Koln' x -> 'Tagged' t ('Kol' x) -> 'Koln' 'O.PGBool'
-- 'eq' :: 'Koln' x -> 'Tagged' t ('Koln' x) -> 'Koln' 'O.PGBool'
-- @
--
-- Any of the above combinations with the arguments fliped is accepted too.
-- Additionally, a 'Comparable' constraint will be required if you try to
-- compare two 'Tisch'-aware columns directly, such as those obtained with
-- @('view' '.' 'col')@:
--
-- @
-- -- Fake type signatures just so that you get an idea:
-- 'eq' :: 'Comparable' t1 c1 t2 c2
--         => 'Tagged' ('TC' t1 c1) a -> 'Tagged' ('TC' t2 c2) b -> 'Koln' 'O.PGBool'
-- @
eq :: forall x a b c. Fk2 x x O.PGBool (Kol x) (Kol x) (Kol O.PGBool) a b c => a -> b -> c
eq = fk2 (liftKol2 (O..==) :: Kol x -> Kol x -> Kol O.PGBool)

-- | Like Opaleye's @('O..==')@, but can accept more arguments than just 'O.Column' (see 'eq').
lt :: forall x a b c. (O.PGOrd x, Fk2 x x O.PGBool (Kol x) (Kol x) (Kol O.PGBool) a b c) => a -> b -> c
lt = fk2 (liftKol2 (O..<) :: Kol x -> Kol x -> Kol O.PGBool)

-- | Like Opaleye's @('O..||')@, but can accept more arguments than just 'O.Column' (see 'eq').
--
-- "Ou" means "or" in French, and it is a great name because it doesn't overlap
-- with 'Prelude.or'. N'est-ce pas?
ou :: Fk2 O.PGBool O.PGBool O.PGBool (Kol O.PGBool) (Kol O.PGBool) (Kol O.PGBool) a b c => a -> b -> c
ou = fk2 (liftKol2 (O..||) :: Kol O.PGBool -> Kol O.PGBool -> Kol O.PGBool)

-- | Like Opaleye's @('O..&&')@, but can accept more arguments than just 'O.Column' (see 'eq').
--
-- "et" means "and" in French, and it is a great name because it doesn't overlap
-- with 'Prelude.and'. N'est-ce pas?
-- et' :: IFunK2 (Kol O.PGBool) (Kol O.PGBool) (Kol O.PGBool) a b c => a -> b -> c
et :: Fk2 O.PGBool O.PGBool O.PGBool (Kol O.PGBool) (Kol O.PGBool) (Kol O.PGBool) a b c => a -> b -> c
et = fk2 (liftKol2 (O..&&) :: Kol O.PGBool -> Kol O.PGBool -> Kol O.PGBool)

--------------------------------------------------------------------------------

-- | Look up a 'Kol' inside some kind of wrapper.
class GetKol (w :: *) (a :: *) | w -> a where getKol :: w -> Kol a
instance GetKol (Kol a) a where getKol = id
instance GetKol (Tagged (TC t c) (Kol a)) a where getKol = unTagged

-- | Look up a 'Koln' inside some kind of wrapper.
class GetKoln w a | w -> a where getKoln :: w -> Koln a
instance GetKoln (Koln a) a where getKoln = id
instance GetKoln (Tagged (TC t c) (Koln a)) a where getKoln = unTagged

--------------------------------------------------------------------------------

-- | Like 'O.isNull', but works for any 'GetKoln'.
isNull :: GetKoln w a => w -> Kol O.PGBool
isNull = UnsafeKol . O.isNull . unKoln . getKoln

-- | Flatten @('Koln' 'O.PGBool')@ or compatible (see 'GetKoln') to
-- @('Kol' 'O.PGBool')@. An outer @NULL@ is converted to @TRUE@.
--
-- This can be used as a function or as a 'O.QueryArr', whatever works best for you.
-- The 'O.QueryArr' support is often convenient when working with 'O.restrict':
--
-- @
-- 'restrict' '<<<' 'nullTrue' -< ...
-- @
nullTrue :: (Arrow f, GetKoln w O.PGBool) => f w (Kol O.PGBool)
nullTrue = arr $ matchKoln (val True) id . getKoln

-- | Flatten @('Koln' 'O.PGBool')@ or compatible (see 'GetKoln') to
-- @('Kol' 'O.PGBool')@. An outer @NULL@ is converted to @FALSE@.
--
-- This can be used as a function or as a 'O.QueryArr', whatever works best for you.
-- The 'O.QueryArr' support is often convenient when working with 'O.restrict':
--
-- @
-- 'restrict' '<<<' 'nullFalse' -< ...
-- @
nullFalse :: (Arrow f, GetKoln w O.PGBool) => f w (Kol O.PGBool)
nullFalse = arr $ matchKoln (val False) id . getKoln

-- | Like Opaleye's 'O.restric', but takes a 'Kol' as input.
restrict :: GetKol w O.PGBool => O.QueryArr w ()
restrict = O.restrict <<^ unKol <<^ getKol

-- | Like Opaleye's 'O.leftJoin', but the predicate is expected to
-- return a @('GetKol' w 'O.PGBool')@.
leftJoin
  :: ( PP.Default O.Unpackspec a a
     , PP.Default O.Unpackspec b b
     , PP.Default OI.NullMaker b nb
     , GetKol gkb O.PGBool)
   => O.Query a -> O.Query b -> ((a, b) -> gkb) -> O.Query (a, nb) -- ^
leftJoin = leftJoinExplicit PP.def PP.def PP.def

-- | Like Opaleye's 'O.leftJoinExplicit', but the predicate is expected to
-- return a @('GetKol' w 'O.PGBool')@.
leftJoinExplicit
  :: GetKol gkb O.PGBool
  => O.Unpackspec a a -> O.Unpackspec b b -> OI.NullMaker b nb
  -> O.Query a -> O.Query b -> ((a, b) -> gkb) -> O.Query (a, nb) -- ^
leftJoinExplicit ua ub nmb qa qb fil =
  O.leftJoinExplicit ua ub nmb qa qb (unKol . getKol . fil)

--------------------------------------------------------------------------------
-- Ordering

-- | Ascending order, no @NULL@s involved.
asc :: (GetKol w b, O.PGOrd b) => (a -> w) -> O.Order a
asc f = O.asc (unKol . getKol . f)

-- | Ascending order, @NULL@s last.
ascnl :: (GetKoln w b, O.PGOrd b) => (a -> w) -> O.Order a
ascnl f = O.asc (unsafeUnNullableColumn . unKoln . getKoln . f)

-- | Ascending order, @NULL@s first.
ascnf :: (GetKoln w b, O.PGOrd b) => (a -> w) -> O.Order a
ascnf f = O.ascNullsFirst (unsafeUnNullableColumn . unKoln . getKoln . f)

-- | Descending order, no @NULL@s involved.
desc :: (GetKol w b, O.PGOrd b) => (a -> w) -> O.Order a
desc f = O.desc (unKol . getKol . f)

-- | Descending order, @NULL@s first.
descnf :: (GetKoln w b, O.PGOrd b) => (a -> w) -> O.Order a
descnf f = O.desc (unsafeUnNullableColumn . unKoln . getKoln . f)

-- | Descending order, @NULL@s last.
descnl :: (GetKoln w b, O.PGOrd b) => (a -> w) -> O.Order a
descnl f = O.descNullsLast (unsafeUnNullableColumn . unKoln . getKoln . f)

--------------------------------------------------------------------------------

ppaUnTagged :: P.Profunctor p => p a b -> p (Tagged ta a) (Tagged tb b)
ppaUnTagged = P.dimap unTagged Tagged
{-# INLINE ppaUnTagged #-}

-- | A generalization of product profunctor adaptors such as 'PP.p1', 'PP.p4', etc.
--
-- The functional dependencies make type inference easier, but also forbid some
-- otherwise acceptable instances. 
class P.Profunctor p => ProductProfunctorAdaptor p l ra rb | p l -> ra rb, p ra rb -> l where
  ppa :: l -> p ra rb

-- | 'HList' of length 0.
instance PP.ProductProfunctor p => ProductProfunctorAdaptor p (HList '[]) (HList '[]) (HList '[]) where
  ppa = const (P.dimap (const ()) (const HNil) PP.empty)
  {-# INLINE ppa #-}

-- | 'HList' of length 1 or more.
instance
    ( PP.ProductProfunctor p
    , ProductProfunctorAdaptor p (HList pabs) (HList as) (HList bs)
    ) => ProductProfunctorAdaptor p (HList (p a1 b1 ': pabs)) (HList (a1 ': as)) (HList (b1 ': bs)) where
  ppa = \(HCons pab1 pabs) -> P.dimap (\(HCons x xs) -> (x,xs)) (uncurry HCons) (pab1 PP.***! ppa pabs)
  {-# INLINABLE ppa #-}

instance
    ( ProductProfunctorAdaptor p (HList pabs) (HList as) (HList bs)
    ) => ProductProfunctorAdaptor p (HL.Record pabs) (HL.Record as) (HL.Record bs) where
  ppa = P.dimap unRecord HL.Record . ppa . unRecord
  {-# INLINE ppa #-}

--------------------------------------------------------------------------------

-- | Orphan. 'Opaleye.SOT.Internal'.
instance (PP.ProductProfunctor p, PP.Default p a b) => PP.Default p (Tagged ta a) (Tagged tb b) where
  def = ppaUnTagged PP.def
  {-# INLINE def #-}

-- | Orphan. 'Opaleye.SOT.Internal'.
instance PP.ProductProfunctor p => PP.Default p (HList '[]) (HList '[]) where
  def = ppa HNil
  {-# INLINE def #-}

-- | Orphan. 'Opaleye.SOT.Internal'.
instance
    ( PP.ProductProfunctor p, PP.Default p a1 b1, PP.Default p (HList as) (HList bs)
    ) => PP.Default p (HList (a1 ': as)) (HList (b1 ': bs)) where
  def = P.dimap (\(HCons x xs) -> (x,xs)) (uncurry HCons) (PP.def PP.***! PP.def)
  {-# INLINABLE def #-}

-- | Orphan. 'Opaleye.SOT.Internal'.
instance
    ( PP.ProductProfunctor p, PP.Default p (HList as) (HList bs)
    ) => PP.Default p (HL.Record as) (HL.Record bs) where
  def = P.dimap unRecord HL.Record PP.def
  {-# INLINE def #-}

-- Maybes on the rhs

-- | Orphan. 'Opaleye.SOT.Internal'.
instance
    ( PP.ProductProfunctor p, PP.Default p a (Maybe b)
    ) => PP.Default p (Tagged ta a) (Maybe (Tagged tb b)) where
  def = P.dimap unTagged (fmap Tagged) PP.def
  {-# INLINE def #-}

-- | Orphan. 'Opaleye.SOT.Internal'. Defaults to 'Just'.
instance PP.ProductProfunctor p => PP.Default p (HList '[]) (Maybe (HList '[])) where
  def = P.rmap Just PP.def
  {-# INLINE def #-}

-- | Orphan. 'Opaleye.SOT.Internal'.
instance
    ( PP.ProductProfunctor p
    , PP.Default p a (Maybe b)
    , PP.Default p (HList as) (Maybe (HList bs))
    ) => PP.Default p (HList (a ': as)) (Maybe (HList (b ': bs))) where
  def = P.dimap (\(HCons a as) -> (a, as))
                (\(mb, mbs) -> HCons <$> mb <*> mbs)
                (PP.def PP.***! PP.def)
  {-# INLINABLE def #-}

-- | Orphan. 'Opaleye.SOT.Internal'.
instance
    ( PP.ProductProfunctor p, PP.Default p (HList as) (Maybe (HList bs))
    ) => PP.Default p (HL.Record as) (Maybe (HL.Record bs)) where
  def = P.dimap unRecord (fmap HL.Record) PP.def
  {-# INLINE def #-}

--------------------------------------------------------------------------------
-- Misc

-- | Apply a same constraint to all the types in the list.
type family All (c :: k -> Constraint) (xs :: [k]) :: Constraint where
  All c '[]       = ()
  All c (x ': xs) = (c x, All c xs)

---

-- | Defunctionalized 'Proxy'. To be used with 'Apply'.
data ProxySym0 (a :: TyFun k *)
type instance Apply ProxySym0 a = Proxy a

class HDistributeProxy (xs :: [k]) where
  hDistributeProxy :: Proxy xs -> HList (List.Map ProxySym0 xs)
instance HDistributeProxy ('[] :: [k]) where
  hDistributeProxy _ = HNil
  {-# INLINE hDistributeProxy #-}
instance forall (x :: k) (xs :: [k]). HDistributeProxy xs => HDistributeProxy (x ': xs) where
  hDistributeProxy _ = HCons (Proxy :: Proxy x) (hDistributeProxy (Proxy :: Proxy xs))
  {-# INLINE hDistributeProxy #-}

---

unRecord :: HL.Record xs -> HList xs
unRecord = \(HL.Record x) -> x
{-# INLINE unRecord #-}

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Belongs in Opaleye

unsafeUnNullableColumn :: O.Column (O.Nullable a) -> O.Column a
unsafeUnNullableColumn = O.unsafeCoerceColumn

pgFloat4 :: Float -> O.Column O.PGFloat4
pgFloat4 = OI.literalColumn . OI.DoubleLit . float2Double

pgFloat8 :: Float -> O.Column O.PGFloat8
pgFloat8 = OI.literalColumn . OI.DoubleLit . float2Double

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Support for overloaded unary operators working on Kol or Koln

class Fk1 a b fa fb xa xb | fa -> a, fb -> b, xa -> a, xb -> b, xa fa fb -> xb where
  -- | Generalize the argument and return type of the given function
  -- so that it works for as many combinations of @('Kol' x)@, @('Koln' x)@,
  -- @('Tagged' ('TC' t c) ('Kol' x))@ or @('Tagged' ('TC' t c) ('Koln' x))@ as
  -- possible.
  fk1 :: (fa -> fb) -> (xa -> xb)

-- Note: possibly some of these instances could be generalized, but it's hard
-- to keep track of them, so I write all the possible combinations explicitely.

-- | kk -> kk
instance Fk1 a b (Kol a) (Kol b) (Kol a) (Kol b) where fk1 f ka = f ka
-- | kk -> nn
instance Fk1 a b (Kol a) (Kol b) (Koln a) (Koln b) where fk1 f na = bindKoln na (mkKoln . f)
-- | kk -> tx
instance Fk1 a b (Kol a) (Kol b) xa xb => Fk1 a b (Kol a) (Kol b) (Tagged (TC t c) xa) xb where fk1 f (Tagged xa) = fk1 f xa
-- | kn -> kn
instance Fk1 a b (Kol a) (Koln b) (Kol a) (Koln b) where fk1 f ka = f ka
-- | kn -> nn
instance Fk1 a b (Kol a) (Koln b) (Koln a) (Koln b) where fk1 f na = bindKoln na f
-- | kn -> tn
instance Fk1 a b (Kol a) (Koln b) xa (Koln b) => Fk1 a b (Kol a) (Koln b) (Tagged (TC t c) xa) (Koln b) where fk1 f (Tagged xa) = fk1 f xa
-- | nk -> kk
instance Fk1 a b (Koln a) (Kol b) (Kol a) (Kol b) where fk1 f ka = f (mkKoln ka)
-- | nk -> nk
instance Fk1 a b (Koln a) (Kol b) (Koln a) (Kol b) where fk1 f na = f na
-- | nk -> tk
instance Fk1 a b (Koln a) (Kol b) xa (Kol b) => Fk1 a b (Koln a) (Kol b) (Tagged (TC t c) xa) (Kol b) where fk1 f (Tagged xa) = fk1 f xa
-- | nn -> kn
instance Fk1 a b (Koln a) (Koln b) (Kol a) (Koln b) where fk1 f ka = f (mkKoln ka)
-- | nn -> nn
instance Fk1 a b (Koln a) (Koln b) (Koln a) (Koln b) where fk1 f na = f na
-- | nn -> tn
instance Fk1 a b (Koln a) (Koln b) xa (Koln b) => Fk1 a b (Koln a) (Koln b) (Tagged (TC t c) xa) (Koln b) where fk1 f (Tagged xa) = fk1 f xa

--------------------------------------------------------------------------------
-- Support for overloaded binary operators working on Kol or Koln

-- | Generalize the arguments and return type of the given function
-- so that it works for as many combinations of @('Kol' x)@, @('Koln' x)@,
-- @('Tagged' ('TC' t c) ('Kol' x))@ or @('Tagged' ('TC' t c) ('Koln' x))@ as
-- possible.
--
-- If the two arguments are of @('Tagged' ('TC' t c))@, then a
-- 'Comparable' constraint will be required on them.
class Fk2 a b c fa fb fc xa xb xc | fa -> a, fb -> b, fc -> c, xa -> a, xb -> b, xc -> c, xa xb fa fb fc -> xc where
  fk2 :: (fa -> fb -> fc) -> (xa -> xb -> xc)

-- Note: possibly some of these instances could be generalized, but it's hard
-- to keep track of them, so I write all the possible combinations explicitely.

-- | kkk -> kkk
instance Fk2 a b c (Kol a) (Kol b) (Kol c) (Kol a) (Kol b) (Kol c) where fk2 f ka kb = f ka kb
-- | kkk -> knn
instance Fk2 a b c (Kol a) (Kol b) (Kol c) (Kol a) (Koln b) (Koln c) where fk2 f ka nb = bindKoln nb (mkKoln . f ka)
-- | kkk -> ktx
instance (Fk2 a b c (Kol a) (Kol b) (Kol c) (Kol a) xb xc) => Fk2 a b c (Kol a) (Kol b) (Kol c) (Kol a) (Tagged (TC tb cb) xb) xc where fk2 f ka (Tagged xb) = fk2 f ka xb
-- | kkk -> nkn
instance Fk2 a b c (Kol a) (Kol b) (Kol c) (Koln a) (Kol b) (Koln c) where fk2 f na kb = bindKoln na (mkKoln . flip f kb)
-- | kkk -> nnn
instance Fk2 a b c (Kol a) (Kol b) (Kol c) (Koln a) (Koln b) (Koln c) where fk2 f na nb = bindKoln na (\ka -> bindKoln nb (mkKoln . f ka))
-- | kkk -> ntn
instance (Fk2 a b c (Kol a) (Kol b) (Kol c) (Koln a) xb (Koln c)) => Fk2 a b c (Kol a) (Kol b) (Kol c) (Koln a) (Tagged (TC tb cb) xb) (Koln c) where fk2 f na (Tagged xb) = fk2 f na xb
-- | kkk -> tkx
instance (Fk2 a b c (Kol a) (Kol b) (Kol c) xa (Kol b) xc) => Fk2 a b c (Kol a) (Kol b) (Kol c) (Tagged (TC ta ca) xa) (Kol b) xc  where fk2 f (Tagged xa) kb = fk2 f xa kb
-- | kkk -> tnk
instance (Fk2 a b c (Kol a) (Kol b) (Kol c) xa (Koln b) (Koln c)) => Fk2 a b c (Kol a) (Kol b) (Kol c) (Tagged (TC ta ca) xa) (Koln b) (Koln c) where fk2 f (Tagged xa) nb = fk2 f xa nb
-- | kkk -> ttx
instance (Fk2 a b c (Kol a) (Kol b) (Kol c) xa xb xc, Comparable ta ca tb cb) => Fk2 a b c (Kol a) (Kol b) (Kol c) (Tagged (TC ta ca) xa) (Tagged (TC tb cb) xb) xc where fk2 f (Tagged xa) (Tagged xb) = fk2 f xa xb

-- | kkn -> kkn
instance Fk2 a b c (Kol a) (Kol b) (Koln c) (Kol a) (Kol b) (Koln c) where fk2 f ka kb = f ka kb
-- | kkn -> knn
instance Fk2 a b c (Kol a) (Kol b) (Koln c) (Kol a) (Koln b) (Koln c) where fk2 f ka nb = bindKoln nb (f ka)
-- | kkn -> ktn
instance (Fk2 a b c (Kol a) (Kol b) (Koln c) (Kol a) xb (Koln c)) => Fk2 a b c (Kol a) (Kol b) (Koln c) (Kol a) (Tagged (TC tb cb) xb) (Koln c) where fk2 f ka (Tagged xb) = fk2 f ka xb
-- | kkn -> nkn
instance Fk2 a b c (Kol a) (Kol b) (Koln c) (Koln a) (Kol b) (Koln c) where fk2 f na kb = bindKoln na (flip f kb)
-- | kkn -> nnn
instance Fk2 a b c (Kol a) (Kol b) (Koln c) (Koln a) (Koln b) (Koln c) where fk2 f na nb = bindKoln na (\ka -> bindKoln nb (f ka))
-- | kkn -> ntn
instance (Fk2 a b c (Kol a) (Kol b) (Koln c) (Koln a) xb (Koln c)) => Fk2 a b c (Kol a) (Kol b) (Koln c) (Koln a) (Tagged (TC tb cb) xb) (Koln c) where fk2 f na (Tagged xb) = fk2 f na xb
-- | kkn -> tkn
instance (Fk2 a b c (Kol a) (Kol b) (Koln c) xa (Kol b) (Koln c)) => Fk2 a b c (Kol a) (Kol b) (Koln c) (Tagged (TC ta ca) xa) (Kol b) (Koln c) where fk2 f (Tagged xa) kb = fk2 f xa kb
-- | kkn -> tnn
instance (Fk2 a b c (Kol a) (Kol b) (Koln c) xa (Koln b) (Koln c)) => Fk2 a b c (Kol a) (Kol b) (Koln c) (Tagged (TC ta ca) xa) (Koln b) (Koln c) where fk2 f (Tagged xa) nb = fk2 f xa nb
-- | kkn -> ttn
instance (Fk2 a b c (Kol a) (Kol b) (Koln c) xa xb (Koln c), Comparable ta ca tb cb) => Fk2 a b c (Kol a) (Kol b) (Koln c) (Tagged (TC ta ca) xa) (Tagged (TC tb cb) xb) (Koln c) where fk2 f (Tagged xa) (Tagged xb) = fk2 f xa xb

-- | knk -> kkk
instance Fk2 a b c (Kol a) (Koln b) (Kol c) (Kol a) (Kol b) (Kol c) where fk2 f ka kb = f ka (mkKoln kb)
-- | knk -> knk
instance Fk2 a b c (Kol a) (Koln b) (Kol c) (Kol a) (Koln b) (Kol c) where fk2 f ka nb = f ka nb
-- | knk -> ktk
instance (Fk2 a b c (Kol a) (Koln b) (Kol c) (Kol a) xb (Kol c)) => Fk2 a b c (Kol a) (Koln b) (Kol c) (Kol a) (Tagged (TC tb cb) xb) (Kol c) where fk2 f ka (Tagged xb) = fk2 f ka xb
-- | knk -> nkn
instance Fk2 a b c (Kol a) (Koln b) (Kol c) (Koln a) (Kol b) (Koln c) where fk2 f na kb = bindKoln na (mkKoln . flip f (mkKoln kb))
-- | knk -> nnn
instance Fk2 a b c (Kol a) (Koln b) (Kol c) (Koln a) (Koln b) (Koln c) where fk2 f na nb = bindKoln na (mkKoln . flip f nb)
-- | knk -> ntn
instance (Fk2 a b c (Kol a) (Koln b) (Kol c) (Koln a) xb (Koln c)) => Fk2 a b c (Kol a) (Koln b) (Kol c) (Koln a) (Tagged (TC tb cb) xb) (Koln c) where fk2 f na (Tagged xb) = fk2 f na xb
-- | knk -> tkx
instance (Fk2 a b c (Kol a) (Koln b) (Kol c) xa (Kol b) xc) => Fk2 a b c (Kol a) (Koln b) (Kol c) (Tagged (TC ta ca) xa) (Kol b) xc  where fk2 f (Tagged xa) kb = fk2 f xa kb
-- | knk -> tnx
instance (Fk2 a b c (Kol a) (Koln b) (Kol c) xa (Koln b) (Koln c)) => Fk2 a b c (Kol a) (Koln b) (Kol c) (Tagged (TC ta ca) xa) (Koln b) (Koln c) where fk2 f (Tagged xa) nb = fk2 f xa nb
-- | knk -> ttx
instance (Fk2 a b c (Kol a) (Koln b) (Kol c) xa xb xc, Comparable ta ca tb cb) => Fk2 a b c (Kol a) (Koln b) (Kol c) (Tagged (TC ta ca) xa) (Tagged (TC tb cb) xb) xc where fk2 f (Tagged xa) (Tagged xb) = fk2 f xa xb

-- | knn -> kkn
instance Fk2 a b c (Kol a) (Koln b) (Koln c) (Kol a) (Kol b) (Koln c) where fk2 f ka kb = f ka (mkKoln kb)
-- | knn -> knn
instance Fk2 a b c (Kol a) (Koln b) (Koln c) (Kol a) (Koln b) (Koln c) where fk2 f ka nb = f ka nb
-- | knn -> ktn
instance (Fk2 a b c (Kol a) (Koln b) (Koln c) (Kol a) xb (Koln c)) => Fk2 a b c (Kol a) (Koln b) (Koln c) (Kol a) (Tagged (TC tb cb) xb) (Koln c) where fk2 f ka (Tagged xb) = fk2 f ka xb
-- | knn -> nkn
instance Fk2 a b c (Kol a) (Koln b) (Koln c) (Koln a) (Kol b) (Koln c) where fk2 f na kb = bindKoln na (flip f (mkKoln kb))
-- | knn -> nnn
instance Fk2 a b c (Kol a) (Koln b) (Koln c) (Koln a) (Koln b) (Koln c) where fk2 f na nb = bindKoln na (flip f nb)
-- | knn -> ntn
instance (Fk2 a b c (Kol a) (Koln b) (Koln c) (Koln a) xb (Koln c)) => Fk2 a b c (Kol a) (Koln b) (Koln c) (Koln a) (Tagged (TC tb cb) xb) (Koln c) where fk2 f na (Tagged xb) = fk2 f na xb
-- | knn -> tkn
instance (Fk2 a b c (Kol a) (Koln b) (Koln c) xa (Kol b) (Koln c)) => Fk2 a b c (Kol a) (Koln b) (Koln c) (Tagged (TC ta ca) xa) (Kol b) (Koln c) where fk2 f (Tagged xa) kb = fk2 f xa kb
-- | knn -> tnn
instance (Fk2 a b c (Kol a) (Koln b) (Koln c) xa (Koln b) (Koln c)) => Fk2 a b c (Kol a) (Koln b) (Koln c) (Tagged (TC ta ca) xa) (Koln b) (Koln c) where fk2 f (Tagged xa) nb = fk2 f xa nb
-- | knn -> ttn
instance (Fk2 a b c (Kol a) (Koln b) (Koln c) xa xb (Koln c), Comparable ta ca tb cb) => Fk2 a b c (Kol a) (Koln b) (Koln c) (Tagged (TC ta ca) xa) (Tagged (TC tb cb) xb) (Koln c) where fk2 f (Tagged xa) (Tagged xb) = fk2 f xa xb

-- | nkk -> kkk
instance Fk2 a b c (Koln a) (Kol b) (Kol c) (Kol a) (Kol b) (Kol c) where fk2 f ka kb = f (mkKoln ka) kb
-- | nkk -> knn
instance Fk2 a b c (Koln a) (Kol b) (Kol c) (Kol a) (Koln b) (Koln c) where fk2 f ka nb = bindKoln nb (mkKoln . f (mkKoln ka))
-- | nkk -> ktx
instance (Fk2 a b c (Koln a) (Kol b) (Kol c) (Kol a) xb xc) => Fk2 a b c (Koln a) (Kol b) (Kol c) (Kol a) (Tagged (TC tb cb) xb) xc where fk2 f ka (Tagged xb) = fk2 f ka xb
-- | nkk -> nkk
instance Fk2 a b c (Koln a) (Kol b) (Kol c) (Koln a) (Kol b) (Kol c) where fk2 f na kb = f na kb
-- | nkk -> nnn
instance Fk2 a b c (Koln a) (Kol b) (Kol c) (Koln a) (Koln b) (Koln c) where fk2 f na nb = bindKoln nb (mkKoln . f na)
-- | nkk -> ntx
instance (Fk2 a b c (Koln a) (Kol b) (Kol c) (Koln a) xb xc) => Fk2 a b c (Koln a) (Kol b) (Kol c) (Koln a) (Tagged (TC tb cb) xb) xc where fk2 f na (Tagged xb) = fk2 f na xb
-- | nkk -> tkk
instance (Fk2 a b c (Koln a) (Kol b) (Kol c) xa (Kol b) xc) => Fk2 a b c (Koln a) (Kol b) (Kol c) (Tagged (TC ta ca) xa) (Kol b) xc  where fk2 f (Tagged xa) kb = fk2 f xa kb
-- | nkk -> tnn
instance (Fk2 a b c (Koln a) (Kol b) (Kol c) xa (Koln b) (Koln c)) => Fk2 a b c (Koln a) (Kol b) (Kol c) (Tagged (TC ta ca) xa) (Koln b) (Koln c) where fk2 f (Tagged xa) nb = fk2 f xa nb
-- | nkk -> ttx
instance (Fk2 a b c (Koln a) (Kol b) (Kol c) xa xb xc, Comparable ta ca tb cb) => Fk2 a b c (Koln a) (Kol b) (Kol c) (Tagged (TC ta ca) xa) (Tagged (TC tb cb) xb) xc where fk2 f (Tagged xa) (Tagged xb) = fk2 f xa xb

-- | nkn -> kkn
instance Fk2 a b c (Koln a) (Kol b) (Koln c) (Kol a) (Kol b) (Koln c) where fk2 f ka kb = f (mkKoln ka) kb
-- | nkn -> knn
instance Fk2 a b c (Koln a) (Kol b) (Koln c) (Kol a) (Koln b) (Koln c) where fk2 f ka nb = bindKoln nb (f (mkKoln ka))
-- | nkn -> ktn
instance (Fk2 a b c (Koln a) (Kol b) (Koln c) (Kol a) xb (Koln c)) => Fk2 a b c (Koln a) (Kol b) (Koln c) (Kol a) (Tagged (TC tb cb) xb) (Koln c) where fk2 f ka (Tagged xb) = fk2 f ka xb
-- | nkn -> nkn
instance Fk2 a b c (Koln a) (Kol b) (Koln c) (Koln a) (Kol b) (Koln c) where fk2 f na kb = f na kb
-- | nkn -> nnn
instance Fk2 a b c (Koln a) (Kol b) (Koln c) (Koln a) (Koln b) (Koln c) where fk2 f na nb = bindKoln nb (f na)
-- | nkn -> ntn
instance (Fk2 a b c (Koln a) (Kol b) (Koln c) (Koln a) xb (Koln c)) => Fk2 a b c (Koln a) (Kol b) (Koln c) (Koln a) (Tagged (TC tb cb) xb) (Koln c) where fk2 f na (Tagged xb) = fk2 f na xb
-- | nkn -> tkn
instance (Fk2 a b c (Koln a) (Kol b) (Koln c) xa (Kol b) (Koln c)) => Fk2 a b c (Koln a) (Kol b) (Koln c) (Tagged (TC ta ca) xa) (Kol b) (Koln c) where fk2 f (Tagged xa) kb = fk2 f xa kb
-- | nkn -> tnn
instance (Fk2 a b c (Koln a) (Kol b) (Koln c) xa (Koln b) (Koln c)) => Fk2 a b c (Koln a) (Kol b) (Koln c) (Tagged (TC ta ca) xa) (Koln b) (Koln c) where fk2 f (Tagged xa) nb = fk2 f xa nb
-- | nkn -> ttn
instance (Fk2 a b c (Koln a) (Kol b) (Koln c) xa xb (Koln c), Comparable ta ca tb cb) => Fk2 a b c (Koln a) (Kol b) (Koln c) (Tagged (TC ta ca) xa) (Tagged (TC tb cb) xb) (Koln c) where fk2 f (Tagged xa) (Tagged xb) = fk2 f xa xb

-- | nnk -> kkk
instance Fk2 a b c (Koln a) (Koln b) (Kol c) (Kol a) (Kol b) (Kol c) where fk2 f ka kb = f (mkKoln ka) (mkKoln kb)
-- | nnk -> knk
instance Fk2 a b c (Koln a) (Koln b) (Kol c) (Kol a) (Koln b) (Kol c) where fk2 f ka nb = f (mkKoln ka) nb
-- | nnk -> ktk
instance (Fk2 a b c (Koln a) (Koln b) (Kol c) (Kol a) xb (Kol c)) => Fk2 a b c (Koln a) (Koln b) (Kol c) (Kol a) (Tagged (TC tb cb) xb) (Kol c) where fk2 f ka (Tagged xb) = fk2 f ka xb
-- | nnk -> nkk
instance Fk2 a b c (Koln a) (Koln b) (Kol c) (Koln a) (Kol b) (Kol c) where fk2 f na kb = f na (mkKoln kb)
-- | nnk -> nnk
instance Fk2 a b c (Koln a) (Koln b) (Kol c) (Koln a) (Koln b) (Kol c) where fk2 f na nb = f na nb
-- | nnk -> ntk
instance (Fk2 a b c (Koln a) (Koln b) (Kol c) (Koln a) xb (Kol c)) => Fk2 a b c (Koln a) (Koln b) (Kol c) (Koln a) (Tagged (TC tb cb) xb) (Kol c) where fk2 f na (Tagged xb) = fk2 f na xb
-- | nnk -> tkk
instance (Fk2 a b c (Koln a) (Koln b) (Kol c) xa (Kol b) (Kol c)) => Fk2 a b c (Koln a) (Koln b) (Kol c) (Tagged (TC ta ca) xa) (Kol b) (Kol c)  where fk2 f (Tagged xa) kb = fk2 f xa kb
-- | nnk -> tnk
instance (Fk2 a b c (Koln a) (Koln b) (Kol c) xa (Koln b) (Kol c)) => Fk2 a b c (Koln a) (Koln b) (Kol c) (Tagged (TC ta ca) xa) (Koln b) (Kol c) where fk2 f (Tagged xa) nb = fk2 f xa nb
-- | nnk -> ttk
instance (Fk2 a b c (Koln a) (Koln b) (Kol c) xa xb (Kol c), Comparable ta ca tb cb) => Fk2 a b c (Koln a) (Koln b) (Kol c) (Tagged (TC ta ca) xa) (Tagged (TC tb cb) xb) (Kol c) where fk2 f (Tagged xa) (Tagged xb) = fk2 f xa xb

-- | nnn -> kkn
instance Fk2 a b c (Koln a) (Koln b) (Koln c) (Kol a) (Kol b) (Koln c) where fk2 f ka kb = f (mkKoln ka) (mkKoln kb)
-- | nnn -> knn
instance Fk2 a b c (Koln a) (Koln b) (Koln c) (Kol a) (Koln b) (Koln c) where fk2 f ka nb = f (mkKoln ka) nb
-- | nnn -> ktn
instance (Fk2 a b c (Koln a) (Koln b) (Koln c) (Kol a) xb (Koln c)) => Fk2 a b c (Koln a) (Koln b) (Koln c) (Kol a) (Tagged (TC tb cb) xb) (Koln c) where fk2 f ka (Tagged xb) = fk2 f ka xb
-- | nnn -> nkn
instance Fk2 a b c (Koln a) (Koln b) (Koln c) (Koln a) (Kol b) (Koln c) where fk2 f na kb = f na (mkKoln kb)
-- | nnn -> nnn
instance Fk2 a b c (Koln a) (Koln b) (Koln c) (Koln a) (Koln b) (Koln c) where fk2 f na nb = f na nb
-- | nnn -> ntn
instance (Fk2 a b c (Koln a) (Koln b) (Koln c) (Koln a) xb (Koln c)) => Fk2 a b c (Koln a) (Koln b) (Koln c) (Koln a) (Tagged (TC tb cb) xb) (Koln c) where fk2 f na (Tagged xb) = fk2 f na xb
-- | nnn -> tkn
instance (Fk2 a b c (Koln a) (Koln b) (Koln c) xa (Kol b) (Koln c)) => Fk2 a b c (Koln a) (Koln b) (Koln c) (Tagged (TC ta ca) xa) (Kol b) (Koln c)  where fk2 f (Tagged xa) kb = fk2 f xa kb
-- | nnk -> tnn
instance (Fk2 a b c (Koln a) (Koln b) (Koln c) xa (Koln b) (Koln c)) => Fk2 a b c (Koln a) (Koln b) (Koln c) (Tagged (TC ta ca) xa) (Koln b) (Koln c) where fk2 f (Tagged xa) nb = fk2 f xa nb
-- | nnn -> ttn
instance (Fk2 a b c (Koln a) (Koln b) (Koln c) xa xb (Koln c), Comparable ta ca tb cb) => Fk2 a b c (Koln a) (Koln b) (Koln c) (Tagged (TC ta ca) xa) (Tagged (TC tb cb) xb) (Koln c) where fk2 f (Tagged xa) (Tagged xb) = fk2 f xa xb

