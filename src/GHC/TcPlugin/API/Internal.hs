{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneKindSignatures #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

{-|
Module: GHC.TcPlugin.API.Internal
Description: Internal module: unsafe operations for type-checking plugins.

This module provides operations to directly lift and unlift computations in
GHC's 'TcM' monad to the various type-checking plugin monads, in the form
of the functions

  > unsafeLiftTcM :: GHC.TcM a -> m a

  > unsafeWithRunInTcM :: ( ( forall a. m a -> GHC.TcM a ) -> GHC.TcM b ) -> m b

It also exposes extra environment available in the solving/rewriting stages:

  > askEvBinds :: TcPluginM Solve GHC.EvBindsVar

  > askRewriteEnv :: TcPluginM Rewrite GHC.RewriteEnv

It is hoped that none of these internal operations are necessary, and that users
can fulfill their needs without importing this internal module.

Please file a bug on the issue tracker if you have encountered a situation
which requires the import of this module.

-}

module GHC.TcPlugin.API.Internal
  ( TcPlugin(..), TcPluginStage(..)
  , TcPluginSolver, TcPluginRewriter
  , TcPluginM(..), MonadTcPlugin(..), MonadTcPluginTypeError(..)
  , TcPluginErrorMessage(..)
  , askEvBinds
  , askRewriteEnv
  , unsafeLiftThroughTcM
  , mkTcPlugin
  , mkTcPluginErrorTy
  )
  where

-- base
import Data.Kind
  ( Constraint, Type )
import GHC.TypeLits
  ( TypeError, ErrorMessage(..) )

-- transformers
import Control.Monad.Trans.Reader
  ( ReaderT(..) )

-- ghc
import qualified GHC
    ( mkModuleName )
import qualified GHC.Builtin.Types
  as GHC
    ( constraintKind )
import qualified GHC.Core.DataCon
  as GHC
    ( promoteDataCon )
import qualified GHC.Core.TyCon
  as GHC
    ( TyCon )
import qualified GHC.Core.TyCo.Rep
  as GHC
    ( PredType, Type(..), TyLit(..) )
import qualified GHC.Core.Type
  as GHC
    ( mkTyConApp, tcTypeKind )
import qualified GHC.Data.FastString
  as GHC
    ( fsLit )
import qualified GHC.Tc.Plugin
  as GHC
    ( findImportedModule
    , lookupOrig, tcLookupDataCon, tcLookupTyCon
    )
import qualified GHC.Tc.Types
  as GHC
    ( RewriteEnv, TcM, TcPlugin(..), TcPluginM
    , TcPluginRewriter, TcPluginRewriteResult
    , TcPluginSolver, TcPluginSolveResult
    , runTcPluginM, unsafeTcPluginTcM
    )
import qualified GHC.Tc.Types.Constraint
  as GHC
    ( Ct )
import qualified GHC.Tc.Types.Evidence
  as GHC
    ( EvBindsVar )
import qualified GHC.Types.Name.Occurrence
  as GHC
    ( mkDataOcc, mkTcOcc )
import qualified GHC.Types.Unique.FM
  as GHC
    ( UniqFM )
import qualified GHC.Unit.Finder
  as GHC
    ( FindResult(..) )

--------------------------------------------------------------------------------
-- Public types and functions.

-- | Stage of a type-checking plugin, used as a data kind.
data TcPluginStage
  = Init
  | Solve
  | Rewrite
  | Stop

-- | The @solve@ function of a type-checking plugin takes in Given, Derived
-- and Wanted constraints, and should return a 'TcPluginSolveResult'
-- indicating which Wanted constraints it could solve, or whether any are
-- insoluble.
type TcPluginSolver
  =  [GHC.Ct] -- ^ Givens
  -> [GHC.Ct] -- ^ Deriveds
  -> [GHC.Ct] -- ^ Wanteds
  -> TcPluginM Solve GHC.TcPluginSolveResult

-- | For rewriting type family applications, a type-checking plugin provides
-- a function of this type for each type family 'TyCon'.
-- 
-- The function is provided with the current set of Given constraints, together
-- with the arguments to the type family.
-- The type family application will always be fully saturated.
type TcPluginRewriter
  =  [GHC.Ct]     -- ^ Givens
  -> [GHC.Type]   -- ^ Type family arguments (saturated)
  -> TcPluginM Rewrite GHC.TcPluginRewriteResult

data TcPlugin = forall s. TcPlugin
  { tcPluginInit    :: TcPluginM Init s
      -- ^ Initialise plugin, when entering type-checker.

  , tcPluginSolve   :: s -> TcPluginSolver
      -- ^ Solve some constraints.
      --
      -- This function will be invoked at two points in the constraint solving
      -- process: after simplification of given constraints, and after
      -- solving of wanted constraints. The two phases can be distinguished
      -- as follows: the deriveds and wanteds will be empty in the first case.
      --
      -- The plugin can either return a contradiction,
      -- or specify that it has solved some constraints (with evidence),
      -- and possibly emit additional wanted constraints.
      --
      -- Use @ \ _ _ _ _ -> pure $ TcPluginOK [] [] @ if your plugin
      -- does not provide this functionality.

  , tcPluginRewrite :: s -> GHC.UniqFM GHC.TyCon TcPluginRewriter
    -- ^ Rewrite saturated type family applications.
    --
    -- The plugin is expected to supply a mapping from type family names to
    -- rewriting functions. For each type family 'TyCon', the plugin should
    -- provide a function which takes in the given constraints and arguments
    -- of a saturated type family application, and return a possible rewriting.
    -- See 'TcPluginRewriter' for the expected shape of such a function.
    --
    -- Use @ const emptyUFM @ if your plugin does not provide this functionality.

  , tcPluginStop    :: s -> TcPluginM Stop ()
   -- ^ Clean up after the plugin, when exiting the type-checker.
  }

-- | The monad used for a type-checker plugin, parametrised by
-- the 'TcPluginStage' of the plugin.
type TcPluginM :: TcPluginStage -> ( Type -> Type )
data family TcPluginM s
newtype instance TcPluginM Init    a = TcPluginInitM    { tcPluginInitM    :: GHC.TcPluginM a }
  deriving newtype ( Functor, Applicative, Monad )
newtype instance TcPluginM Solve   a = TcPluginSolveM   { tcPluginSolveM   :: BuiltinDefs -> GHC.EvBindsVar -> GHC.TcPluginM a }
  deriving ( Functor, Applicative, Monad )
    via ( ReaderT BuiltinDefs ( ReaderT GHC.EvBindsVar GHC.TcPluginM ) ) 
newtype instance TcPluginM Rewrite a = TcPluginRewriteM { tcPluginRewriteM :: BuiltinDefs -> GHC.RewriteEnv -> GHC.TcPluginM a }
  deriving ( Functor, Applicative, Monad )
    via ( ReaderT BuiltinDefs ( ReaderT GHC.RewriteEnv GHC.TcPluginM ) )
newtype instance TcPluginM Stop    a = TcPluginStopM    { tcPluginStopM    :: GHC.TcPluginM a }
  deriving newtype ( Functor, Applicative, Monad )

askEvBinds :: TcPluginM Solve GHC.EvBindsVar
askEvBinds = TcPluginSolveM ( \ _ evBinds -> pure evBinds )

askRewriteEnv :: TcPluginM Rewrite GHC.RewriteEnv
askRewriteEnv = TcPluginRewriteM ( \ _ rewriteEnv -> pure rewriteEnv )

-- | A 'MonadTcPlugin' is essentially a reader monad over GHC's 'TcM' monad.
--
-- This means we have both a @lift@ and an @unlift@ operation,
-- similar to @MonadUnliftIO@ or @MonadBaseControl@.
--
-- See for instance 'unsafeLiftThroughTcM', which is an example of function that
-- one would not be able to write using only a @lift@ operation.
type  MonadTcPlugin :: ( Type -> Type ) -> Constraint
class Monad m => MonadTcPlugin m where

  {-# MINIMAL liftTcPluginM, unsafeWithRunInTcM #-}

  -- N.B.: these methods are not re-exported from the main module.

  -- | Lift a computation from GHC's 'GHC.TcPluginM' monad.
  liftTcPluginM :: GHC.TcPluginM a -> m a

  -- | Lift a computation from the 'TcM' monad.
  unsafeLiftTcM :: GHC.TcM a -> m a
  unsafeLiftTcM = liftTcPluginM . GHC.unsafeTcPluginTcM

  -- | Unlift a computation from the 'TcM' monad.
  --
  -- If this type signature seems confusing, I recommend reading Alexis King's
  -- excellent blog post on @MonadBaseControl@:
  -- 
  -- <https://lexi-lambda.github.io/blog/2019/09/07/demystifying-monadbasecontrol/ Demystifying MonadBaseControl>
  unsafeWithRunInTcM :: ( ( forall a. m a -> GHC.TcM a ) -> GHC.TcM b ) -> m b

instance MonadTcPlugin ( TcPluginM Init ) where
  liftTcPluginM = TcPluginInitM
  unsafeWithRunInTcM runInTcM = unsafeLiftTcM $ runInTcM ( GHC.runTcPluginM . tcPluginInitM )
instance MonadTcPlugin ( TcPluginM Solve ) where
  liftTcPluginM  = TcPluginSolveM . ( \ ma _ _ -> ma )
  unsafeWithRunInTcM runInTcM
    = TcPluginSolveM . ( \ f builtinDefs evBinds -> GHC.unsafeTcPluginTcM $ f builtinDefs evBinds )
    $ \ builtinDefs evBindsVar ->
      runInTcM ( GHC.runTcPluginM . ( \ f -> f builtinDefs evBindsVar ) . tcPluginSolveM )
instance MonadTcPlugin ( TcPluginM Rewrite ) where
  liftTcPluginM = TcPluginRewriteM . ( \ ma _ _ -> ma )
  unsafeWithRunInTcM runInTcM
    = TcPluginRewriteM . ( \ f builtinDefs rewriteEnv -> GHC.unsafeTcPluginTcM $ f builtinDefs rewriteEnv )
    $ \ builtinDefs rewriteEnv ->
      runInTcM ( GHC.runTcPluginM . ( \ f -> f builtinDefs rewriteEnv ) . tcPluginRewriteM )
instance MonadTcPlugin ( TcPluginM Stop ) where
  liftTcPluginM = TcPluginStopM
  unsafeWithRunInTcM runInTcM = unsafeLiftTcM $ runInTcM ( GHC.runTcPluginM . tcPluginStopM )

unsafeLiftThroughTcM :: MonadTcPlugin m => ( GHC.TcM a -> GHC.TcM b ) -> m a -> m b
unsafeLiftThroughTcM f ma = unsafeWithRunInTcM \ runInTcM -> f ( runInTcM ma )

-- | Create a type-checker plugin for GHC from this API.
mkTcPlugin :: TcPlugin -> GHC.TcPlugin
mkTcPlugin ( TcPlugin { tcPluginInit = tcPluginInit :: TcPluginM Init userDefs, tcPluginSolve, tcPluginRewrite, tcPluginStop } ) =
  GHC.TcPlugin
    { GHC.tcPluginInit    = adaptUserInit    tcPluginInit
    , GHC.tcPluginSolve   = adaptUserSolve   tcPluginSolve
    , GHC.tcPluginRewrite = adaptUserRewrite tcPluginRewrite
    , GHC.tcPluginStop    = adaptUserStop    tcPluginStop
    }
  where
    adaptUserInit :: TcPluginM Init userDefs -> GHC.TcPluginM ( TcPluginDefs userDefs )
    adaptUserInit userInit = do
      tcPluginBuiltinDefs <- initBuiltinDefs
      tcPluginUserDefs    <- tcPluginInitM userInit
      pure ( TcPluginDefs { tcPluginBuiltinDefs, tcPluginUserDefs })
    
    adaptUserSolve :: ( userDefs -> TcPluginSolver )
                   -> TcPluginDefs userDefs -> GHC.EvBindsVar -> GHC.TcPluginSolver
    adaptUserSolve userSolve ( TcPluginDefs { tcPluginUserDefs, tcPluginBuiltinDefs }) evBindsVar
      = \ givens deriveds wanteds ->
        tcPluginSolveM ( userSolve tcPluginUserDefs givens deriveds wanteds ) tcPluginBuiltinDefs evBindsVar

    adaptUserRewrite :: ( userDefs -> GHC.UniqFM GHC.TyCon TcPluginRewriter )
                     -> TcPluginDefs userDefs -> GHC.UniqFM GHC.TyCon GHC.TcPluginRewriter
    adaptUserRewrite userRewrite ( TcPluginDefs { tcPluginUserDefs, tcPluginBuiltinDefs })
      = fmap ( \ userRewriter rewriteEnv givens tys -> tcPluginRewriteM ( userRewriter givens tys ) tcPluginBuiltinDefs rewriteEnv )
          ( userRewrite tcPluginUserDefs )

    adaptUserStop :: ( userDefs -> TcPluginM Stop () ) -> TcPluginDefs userDefs -> GHC.TcPluginM ()
    adaptUserStop userStop ( TcPluginDefs { tcPluginUserDefs } ) = tcPluginStopM $ userStop tcPluginUserDefs

-- | Monads for type-checking plugins which are able to throw type errors.
--
-- These are the monads for to 'tcPluginSolve' and 'tcPluginRewrite';
-- it is not possible to throw type errors in 'tcPluginInit' or 'tcPluginStop'.
type  MonadTcPluginTypeError :: ( Type -> Type ) -> Constraint
class MonadTcPlugin m => MonadTcPluginTypeError m where
  askBuiltins :: m BuiltinDefs
instance MonadTcPluginTypeError ( TcPluginM Solve ) where
  askBuiltins = TcPluginSolveM   ( \ builtinDefs _ -> pure builtinDefs )
instance MonadTcPluginTypeError ( TcPluginM Rewrite ) where
  askBuiltins = TcPluginRewriteM ( \ builtinDefs _ -> pure builtinDefs )

instance TypeError ( 'Text "Cannot throw type errors in 'tcPluginInit'." )
      => MonadTcPluginTypeError ( TcPluginM Init ) where
  askBuiltins = error "Cannot throw type errors in 'tcPluginInit'."
instance TypeError ( 'Text "Cannot throw type errors in 'tcPluginStop'." )
      => MonadTcPluginTypeError ( TcPluginM Stop ) where
  askBuiltins = error "Cannot throw type errors in 'tcPluginStop'."

-- | Use this type like 'GHC.TypeLits.ErrorMessage' to write an error message.
-- This error message can then be thrown at the type-level by the plugin,
-- by emitting a wanted constraint whose predicate is obtained from 'mkTcPluginErrorTy'.
-- 
-- A 'CtLoc' will still need to be provided in order to inform GHC of the
-- origin of the error (e.g.: which part of the source code should be
-- highlighted?). See 'setCtLocM'.
data TcPluginErrorMessage
  = Txt !String
  -- ^ Show the text as is.
  | PrintType !GHC.Type
  -- ^ Pretty print the given type.
  | (:|:) !TcPluginErrorMessage !TcPluginErrorMessage
  -- ^ Put two messages side by side.
  | (:-:) !TcPluginErrorMessage !TcPluginErrorMessage
  -- ^ Stack two messages vertically.
infixl 5 :|:
infixl 6 :-:

-- | Create an error type with the desired error message.
--
-- The result can be paired with a 'GHC.CtLoc' in order to throw a type error,
-- for instance by using 'GHC.TcPlugin.API.newWanted'.
mkTcPluginErrorTy :: MonadTcPluginTypeError m => TcPluginErrorMessage -> m GHC.PredType
mkTcPluginErrorTy msg = do
  builtinDefs@( BuiltinDefs { typeErrorTyCon } ) <- askBuiltins
  let
    errorMsgTy :: GHC.PredType
    errorMsgTy = interpretErrorMessage builtinDefs msg
  pure $ GHC.mkTyConApp typeErrorTyCon [ GHC.constraintKind, errorMsgTy ]

--------------------------------------------------------------------------------
-- Private types and functions.
-- Not exposed at all, even from the internal module.

data BuiltinDefs =
  BuiltinDefs
    { typeErrorTyCon :: !GHC.TyCon
    , textTyCon      :: !GHC.TyCon
    , showTypeTyCon  :: !GHC.TyCon
    , concatTyCon    :: !GHC.TyCon
    , vcatTyCon      :: !GHC.TyCon
    }

data TcPluginDefs s
  = TcPluginDefs
  { tcPluginBuiltinDefs :: !BuiltinDefs
  , tcPluginUserDefs    :: !s
  }

initBuiltinDefs :: GHC.TcPluginM BuiltinDefs
initBuiltinDefs = do
  findTypeLits   <- GHC.findImportedModule ( GHC.mkModuleName "GHC.TypeLits" ) ( Just $ GHC.fsLit "base" )
  typeLitsModule <- case findTypeLits of
    GHC.Found _ res     -> pure res
    GHC.FoundMultiple _ -> error $ "ghc-tcplugin-api: found multiple modules named 'GHC.TypeLits' in 'base' package."
    _                   -> error $ "ghc-tcplugin-api: could not find any module named 'GHC.TypeLits' in 'base' package."
  typeErrorTyCon  <-                           GHC.tcLookupTyCon   =<< GHC.lookupOrig typeLitsModule ( GHC.mkTcOcc   "TypeError" )
  textTyCon       <- fmap GHC.promoteDataCon . GHC.tcLookupDataCon =<< GHC.lookupOrig typeLitsModule ( GHC.mkDataOcc "Text"      )
  showTypeTyCon   <- fmap GHC.promoteDataCon . GHC.tcLookupDataCon =<< GHC.lookupOrig typeLitsModule ( GHC.mkDataOcc "ShowType"  )
  concatTyCon     <- fmap GHC.promoteDataCon . GHC.tcLookupDataCon =<< GHC.lookupOrig typeLitsModule ( GHC.mkDataOcc ":<>:"      )
  vcatTyCon       <- fmap GHC.promoteDataCon . GHC.tcLookupDataCon =<< GHC.lookupOrig typeLitsModule ( GHC.mkDataOcc ":$$:"      )
  pure ( BuiltinDefs { .. } )

interpretErrorMessage :: BuiltinDefs -> TcPluginErrorMessage -> GHC.PredType
interpretErrorMessage ( BuiltinDefs { .. } ) = go
  where
    go :: TcPluginErrorMessage -> GHC.PredType
    go ( Txt str ) =
      GHC.mkTyConApp textTyCon [ GHC.LitTy . GHC.StrTyLit . GHC.fsLit $ str ]
    go ( PrintType ty ) =
      GHC.mkTyConApp showTypeTyCon [ GHC.tcTypeKind ty, ty ]
        -- The kind gets ignored by GHC when printing the error message (see GHC.Core.Type.pprUserTypeErrorTy).
        -- However, including the wrong kind can lead to ASSERT failures, so we compute the kind and pass it.
    go ( msg1 :|: msg2 ) =
      GHC.mkTyConApp concatTyCon [ go msg1, go msg2 ]
    go ( msg1 :-: msg2 ) =
      GHC.mkTyConApp vcatTyCon [ go msg1, go msg2 ]
