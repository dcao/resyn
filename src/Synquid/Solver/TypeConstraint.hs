{-# LANGUAGE FlexibleContexts #-}

-- | Incremental solving of subtyping and well-formedness constraints
module Synquid.Solver.TypeConstraint (
  ErrorMessage,
  typingConstraints,
  typeAssignment,
  qualifierMap,
  candidates,
  errorContext,
  addTypingConstraint,
  addFixedUnknown,
  setUnknownRecheck,
  simplifyAllConstraints,
  solveAllCandidates,
  matchConsType,
  hasPotentialScrutinees,
  freshId,
  freshVar,
  currentAssignment,
  finalizeType,
  finalizeProgram,
  allScalars,
  processAllConstraints,
  generateAllHornClauses,
  solveHornClauses,
  processAllPredicates,
  checkTypeConsistency,
  solveTypeConstraints
) where

import Synquid.Logic
import Synquid.Type hiding (set)
import Synquid.Program
import Synquid.Error
import Synquid.Pretty
import Synquid.Util
import Synquid.Resolver (addAllVariables)
import Synquid.Solver.Monad
import Synquid.Solver.Util
import Synquid.Solver.Resource

import Data.Maybe
import Data.List 
import qualified Data.Set as Set
import Data.Set (Set)
import qualified Data.Map as Map
import Data.Map (Map)
import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Trans.Except
import Control.Lens hiding (both)
import Debug.Trace

{- Top-level constraint solving interface -}

-- | Solve @typingConstraints@: either strengthen the current candidates and return shapeless type constraints or fail
solveTypeConstraints :: (MonadSMT s, MonadHorn s) => TCSolver s ()
solveTypeConstraints = do
  simplifyAllConstraints

  scs <- use simpleConstraints
  writeLog 2 (text "Simple Constraints" $+$ nest 2 (vsep (map pretty scs)))
  processAllPredicates
  processAllConstraints
  generateAllHornClauses

  solveHornClauses
  checkTypeConsistency

  res <- asks _checkResourceBounds
  when res $ checkResources scs 

  hornClauses .= []
  consistencyChecks .= []

-- | Impose typing constraint @c@ on the programs
addTypingConstraint c = over typingConstraints (nub . (c :))

{- Implementation -}

-- | Decompose and unify typing constraints;
-- return shapeless type constraints: constraints involving only free type variables, which impose no restrictions yet, but might in the future
simplifyAllConstraints :: MonadHorn s => TCSolver s ()
simplifyAllConstraints = do
  tcs <- use typingConstraints
  writeLog 3 $ nest 2 $ text "Typing Constraints" $+$ vsep (map pretty tcs)
  typingConstraints .= []
  tass <- use typeAssignment
  mapM_ simplifyConstraint tcs

  -- If type assignment has changed, we might be able to process more shapeless constraints:
  tass' <- use typeAssignment
  writeLog 2 $ nest 2 $ text "Type assignment" $+$ vMapDoc text pretty tass'

  when (Map.size tass' > Map.size tass) simplifyAllConstraints

-- | Assign unknowns to all free predicate variables
processAllPredicates :: MonadHorn s => TCSolver s ()
processAllPredicates = do
  tcs <- use typingConstraints
  typingConstraints .= []
  mapM_ processPredicate tcs

  pass <- use predAssignment
  writeLog 3 (nest 2 $ text "Pred assignment" $+$ vMapDoc text pretty pass)

-- | Eliminate type and predicate variables, generate qualifier maps
processAllConstraints :: MonadHorn s => TCSolver s ()
processAllConstraints = do
  tcs <- use simpleConstraints
  simpleConstraints .= []
  mapM_ processConstraint tcs

-- | Convert simple subtyping constraints into horn clauses
generateAllHornClauses :: (MonadHorn s, MonadSMT s) => TCSolver s ()
generateAllHornClauses = do
  tcs <- use simpleConstraints
  simpleConstraints .= []
  mapM_ generateHornClauses tcs

-- | Refine the current liquid assignments using the horn clauses
solveHornClauses :: MonadHorn s => TCSolver s ()
solveHornClauses = do
  clauses <- use hornClauses
  qmap <- use qualifierMap
  cands <- use candidates
  env <- use initEnv
  cands' <- lift . lift . lift $ refineCandidates (map fst clauses) qmap (instantiateConsAxioms env Nothing) cands

  when (null cands') (throwError $ text "Cannot find sufficiently strong refinements")
  candidates .= cands'

solveAllCandidates :: MonadHorn s => TCSolver s ()
solveAllCandidates = do
  cands <- use candidates
  cands' <- concat <$> mapM solveCandidate cands
  candidates .= cands'
  where
    solveCandidate c@(Candidate s valids invalids _) =
      if Set.null invalids
        then return [c]
        else do
          qmap <- use qualifierMap
          env <- use initEnv
          cands' <- lift . lift . lift $ refineCandidates [] qmap (instantiateConsAxioms env Nothing) [c]
          concat <$> mapM solveCandidate cands'

-- | Filter out liquid assignments that are too strong for current consistency checks
checkTypeConsistency :: MonadHorn s => TCSolver s ()
checkTypeConsistency = do
  clauses <- use consistencyChecks
  cands <- use candidates
  env <- use initEnv
  cands' <- lift . lift . lift $ checkCandidates True clauses (instantiateConsAxioms env Nothing) cands
  when (null cands') (throwError $ text "Found inconsistent refinements")
  candidates .= cands'

-- | Simplify @c@ into a set of simple and shapeless constraints, possibly extended the current type assignment or predicate assignment
simplifyConstraint :: MonadHorn s => Constraint -> TCSolver s ()
simplifyConstraint c = do
  tass <- use typeAssignment
  pass <- use predAssignment
  simplifyConstraint' tass pass c

-- Any type: drop
simplifyConstraint' _ _ (Subtype _ _ AnyT _ _) = return ()
simplifyConstraint' _ _ (Subtype _ AnyT _ _ _) = return ()
simplifyConstraint' _ _ (WellFormed _ AnyT) = return ()
simplifyConstraint' _ _ (SharedType _ _ AnyT _ _) = return ()
simplifyConstraint' _ _ (SharedType _ _ _ AnyT _) = return ()
simplifyConstraint' _ _ (SharedType _ _ _ _ AnyT) = return ()
-- Any datatype: drop only if lhs is a datatype
simplifyConstraint' _ _ (Subtype _ (ScalarT (DatatypeT _ _ _) _ _) t _ _) | t == anyDatatype = return ()
-- Well-formedness of a known predicate drop
simplifyConstraint' _ pass c@(WellFormedPredicate _ _ p) | p `Map.member` pass = return ()

-- Type variable with known assignment: substitute
simplifyConstraint' tass _ (Subtype env tv@(ScalarT (TypeVarT _ a _) _ _) t consistent label) | a `Map.member` tass
  = simplifyConstraint (Subtype env (typeSubstitute tass tv) t consistent label)
simplifyConstraint' tass _ (Subtype env t tv@(ScalarT (TypeVarT _ a _) _ _) consistent label) | a `Map.member` tass
  = simplifyConstraint (Subtype env t (typeSubstitute tass tv) consistent label)
simplifyConstraint' tass _ (WellFormed env tv@(ScalarT (TypeVarT _ a _) _ _)) | a `Map.member` tass
  = simplifyConstraint (WellFormed env (typeSubstitute tass tv))
simplifyConstraint' tass _ (SharedType env name tv@(ScalarT (TypeVarT _ a _) _ _) t2 t3) | a `Map.member` tass 
  = simplifyConstraint (SharedType env name (typeSubstitute tass tv) t2 t3)
simplifyConstraint' tass _ (SharedType env name t1 tv@(ScalarT (TypeVarT _ a _) _ _) t3) | a `Map.member` tass 
  = simplifyConstraint (SharedType env name t1 (typeSubstitute tass tv) t3)
simplifyConstraint' tass _ (SharedType env name t1 t2 tv@(ScalarT (TypeVarT _ a _) _ _)) | a `Map.member` tass 
  = simplifyConstraint (SharedType env name t1 t2 (typeSubstitute tass tv))

-- Two unknown free variables: nothing can be done for now
simplifyConstraint' _ _ c@(Subtype env (ScalarT (TypeVarT _ a _) _ _) (ScalarT (TypeVarT _ b _) _ _) _ _) | not (isBound env a) && not (isBound env b)
  = if a == b
      then error $ show $ text "simplifyConstraint: equal type variables on both sides"
      else ifM (use isFinal)
            (do -- This is a final pass: assign an arbitrary type to one of the variables
              addTypeAssignment a intAll
              simplifyConstraint c)
            (modify $ addTypingConstraint c)
simplifyConstraint' _ _ c@(WellFormed env (ScalarT (TypeVarT _ a _) _ _)) | not (isBound env a)
  = modify $ addTypingConstraint c
simplifyConstraint' _ _ c@(WellFormedPredicate _ _ _) = modify $ addTypingConstraint c

-- Let types: extend environment (has to be done before trying to extend the type assignment)
simplifyConstraint' _ _ (Subtype env (LetT x tDef tBody) t consistent label)
  = simplifyConstraint (Subtype (addVariable x tDef env) tBody t consistent label) -- ToDo: make x unique?
simplifyConstraint' _ _ (Subtype env t (LetT x tDef tBody) consistent label)
  = simplifyConstraint (Subtype (addVariable x tDef env) t tBody consistent label) -- ToDo: make x unique?
simplifyConstraint' _ _ (SharedType env v (LetT x tDef tBody) tl tr) =  simplifyConstraint (SharedType (addVariable x tDef env) v tBody tl tr)
simplifyConstraint' _ _ (SharedType env v t (LetT x tDef tBody) tr) = simplifyConstraint (SharedType (addVariable x tDef env) v t tBody tr)
simplifyConstraint' _ _ (SharedType env v t tl (LetT x tDef tBody)) = simplifyConstraint (SharedType (addVariable x tDef env) v t tl tBody)

-- Unknown free variable and a type: extend type assignment
simplifyConstraint' _ _ c@(Subtype env (ScalarT (TypeVarT _ a _) _ _) t _ _) | not (isBound env a)
  = unify env a t >> simplifyConstraint c
simplifyConstraint' _ _ c@(Subtype env t (ScalarT (TypeVarT _ a _) _ _) _ _) | not (isBound env a)
  = unify env a t >> simplifyConstraint c

-- Compound types: decompose
-- TODO: do something with potential?
simplifyConstraint' _ _ (Subtype env (ScalarT (DatatypeT name (tArg:tArgs) pArgs) fml pot) (ScalarT (DatatypeT name' (tArg':tArgs') pArgs') fml' pot') consistent label)
  = do
      simplifyConstraint (Subtype env tArg tArg' consistent label)
      simplifyConstraint (Subtype env (ScalarT (DatatypeT name tArgs pArgs) fml pot) (ScalarT (DatatypeT name' tArgs' pArgs') fml' pot') consistent label)
simplifyConstraint' _ _ (Subtype env (ScalarT (DatatypeT name [] (pArg:pArgs)) fml pot) (ScalarT (DatatypeT name' [] (pArg':pArgs')) fml' pot') consistent label)
  = do
      let variances = _predVariances ((env ^. datatypes) Map.! name)
      let isContra = variances !! (length variances - length pArgs - 1) -- Is pArg contravariant?
      if isContra
        then simplifyConstraint (Subtype env (int pArg') (int pArg) consistent label)
        else simplifyConstraint (Subtype env (int pArg) (int pArg') consistent label)
      simplifyConstraint (Subtype env (ScalarT (DatatypeT name [] pArgs) fml pot) (ScalarT (DatatypeT name' [] pArgs') fml' pot') consistent label)
simplifyConstraint' _ _ (Subtype env (FunctionT x tArg1 tRes1 _) (FunctionT y tArg2 tRes2 _) False label)
  = do
      simplifyConstraint (Subtype env tArg2 tArg1 False label)
      if isScalarType tArg1
        then simplifyConstraint (Subtype (addVariable y tArg2 env) (renameVar (isBound env) x y tArg1 tRes1) tRes2 False label)
        else simplifyConstraint (Subtype env tRes1 tRes2 False label)
simplifyConstraint' _ _ (Subtype env (FunctionT x tArg1 tRes1 _) (FunctionT y tArg2 tRes2 _) True label)
  = if isScalarType tArg1
      then simplifyConstraint (Subtype (addVariable x tArg1 env) tRes1 tRes2 True label)
      else simplifyConstraint (Subtype env tRes1 tRes2 True label)
simplifyConstraint' _ _ c@(WellFormed env (ScalarT (DatatypeT name tArgs _) fml pot))
  = do
      mapM_ (simplifyConstraint . WellFormed env) tArgs
      simpleConstraints %= (c :)
simplifyConstraint' _ _ (WellFormed env (FunctionT x tArg tRes _))
  = do
      simplifyConstraint (WellFormed env tArg)
      simplifyConstraint (WellFormed (addVariable x tArg env) tRes)
simplifyConstraint' _ _ (WellFormed env (LetT x tDef tBody))
  = simplifyConstraint (WellFormed (addVariable x tDef env) tBody)

-- Simple constraint: return
simplifyConstraint' _ _ c@(Subtype _ (ScalarT baseT _ _) (ScalarT baseT' _ _) _ _) | equalShape baseT baseT' = simpleConstraints %= (c :)
simplifyConstraint' _ _ c@(WellFormed _ (ScalarT baseT _ _)) = simpleConstraints %= (c :)
simplifyConstraint' _ _ c@(WellFormedCond _ _) = simpleConstraints %= (c :)
simplifyConstraint' _ _ c@(WellFormedMatchCond _ _) = simpleConstraints %= (c :)
-- Otherwise (shape mismatch): fail
simplifyConstraint' _ _ (Subtype _ t t' _ _) = 
  throwError $ text  "Cannot match shape" <+> squotes (pretty $ shape t) $+$ text "with shape" <+> squotes (pretty $ shape t')
-- TODO: actually simplify! -- need to check that shapes are equal and drop any splitting constraints from non-scalar types.
simplifyConstraint' _ _ c@SharedType{} = simpleConstraints %= (c :)

-- | Unify type variable @a@ with type @t@ or fail if @a@ occurs in @t@
unify env a t = if a `Set.member` typeVarsOf t
  then error $ show $ text "simplifyConstraint: type variable occurs in the other type"
  else do
    t' <- fresh env t
    writeLog 3 (text "UNIFY" <+> text a <+> text "WITH" <+> pretty t <+> text "PRODUCING" <+> pretty t')
    addTypeAssignment a t'

-- Predicate well-formedness: shapeless or simple depending on type variables
processPredicate c@(WellFormedPredicate env argSorts p) = do
  tass <- use typeAssignment
  let typeVars = Set.toList $ Set.unions $ map typeVarsOfSort argSorts
  if any (isFreeVariable tass) typeVars
    then do
      writeLog 3 $ text "WARNING: free vars in predicate" <+> pretty c
      modify $ addTypingConstraint c -- Still has type variables: cannot determine shape
    else do
      -- u <- freshId "U"
      let u = p
      addPredAssignment p (Unknown Map.empty u)
      let argSorts' = map (sortSubstitute $ asSortSubst tass) argSorts
      let args = zipWith Var argSorts' deBrujns
      let env' = typeSubstituteEnv tass env
      let vars = allScalars env'
      pq <- asks _predQualsGen
      addQuals u (pq (addAllVariables args env') args vars)
  where
    isFreeVariable tass a = not (isBound env a) && not (Map.member a tass)
processPredicate c = modify $ addTypingConstraint c

-- | Eliminate type and predicate variables from simple constraints, create qualifier maps, split measure-based subtyping constraints
processConstraint :: MonadHorn s => Constraint -> TCSolver s ()
processConstraint c@(Subtype env (ScalarT baseTL l potl) (ScalarT baseTR r potr) False label) | equalShape baseTL baseTR
  = unless (l == ffalse || r == ftrue) $ do
      tass <- use typeAssignment
      pass <- use predAssignment
      let subst = sortSubstituteFml (asSortSubst tass) . substitutePredicate pass
      let l' = subst l
      let r' = subst r
      let potl' = subst potl
      let potr' = subst potr
      let c' = Subtype env (ScalarT baseTL l' potl') (ScalarT baseTR r' potr') False label
      if Set.null $ (predsOf l' `Set.union` predsOf r') Set.\\ Map.keysSet (allPredicates env)
          then case baseTL of -- Subtyping of datatypes: try splitting into individual constraints between measures
                DatatypeT dtName _ _ -> do
                  let measures = Map.keysSet $ allMeasuresOf dtName env
                  let isAbstract = null $ ((env ^. datatypes) Map.! dtName) ^. constructors
                  let vals = filter (\v -> varName v == valueVarName) . Set.toList . varsOf $ r'
                  let rConjuncts = conjunctsOf r'
                  doSplit <- asks _tcSolverSplitMeasures
                  if not doSplit || isAbstract || null vals || (not . Set.null . unknownsOf) (l' |&| r') -- TODO: unknowns can be split if we know their potential valuations
                    then simpleConstraints %= (c' :) -- Constraint has unknowns (or RHS doesn't contain _v)
                    else case splitByPredicate measures (head vals) (Set.toList rConjuncts) of
                          Nothing -> simpleConstraints %= (c' :) -- RHS cannot be split, add whole thing
                          Just mr -> if rConjuncts `Set.isSubsetOf` Set.unions (Map.elems mr)
                                      then do
                                        let lConjuncts = conjunctsOf $ instantiateCons (head vals) l'
                                        case splitByPredicate measures (head vals) (Set.toList lConjuncts) of -- Every conjunct of RHS is about some `m _v` (where m in measures)
                                            Nothing -> simpleConstraints %= (c' :) -- LHS cannot be split, add whole thing for now
                                            Just ml -> mapM_ (addSplitConstraint ml) (toDisjointGroups mr)
                                      else simpleConstraints %= (c' :) -- Some conjuncts of RHS are no covered (that is, do not contains _v), add whole thing
                _ -> simpleConstraints %= (c' :)
        else modify $ addTypingConstraint c -- Constraint contains free predicate: add back and wait until more type variables get unified, so predicate variables can be instantiated
  where
    instantiateCons val fml@(Binary Eq v (Cons _ _ _)) | v == val = conjunction $ instantiateConsAxioms env (Just val) fml
    instantiateCons _ fml = fml
    -- TODO: do better than defPotential!
    addSplitConstraint :: MonadHorn s => Map Id (Set Formula) -> (Set Id, Set Formula) -> TCSolver s ()
    addSplitConstraint ml (measures, rConjuncts) = do
      let rhs = conjunction rConjuncts
      let lhs = conjunction $ setConcatMap (\measure -> Map.findWithDefault Set.empty measure ml) measures
      let c' = Subtype env (ScalarT baseTL lhs potl) (ScalarT baseTR rhs potr) False label
      simpleConstraints %= (c' :)

processConstraint (Subtype env (ScalarT baseTL l potl) (ScalarT baseTR r potr) True label) | equalShape baseTL baseTR
  = do
      tass <- use typeAssignment
      pass <- use predAssignment
      let subst = sortSubstituteFml (asSortSubst tass) . substitutePredicate pass
      let l' = subst l
      let r' = subst r
      let potl' = subst potl 
      let potr' = subst potr
      unless (l' == ftrue || r' == ftrue) $ simpleConstraints %= (Subtype env (ScalarT baseTL l' potl') (ScalarT baseTR r' potr') True label :)
processConstraint (WellFormed env t@(ScalarT baseT fml pot))
  = case fml of
      Unknown _ u -> do
        qmap <- use qualifierMap
        tass <- use typeAssignment
        tq <- asks _typeQualsGen
        -- Only add qualifiers if it's a new variable; multiple well-formedness constraints could have been added for constructors
        let env' = typeSubstituteEnv tass env
        let env'' = addVariable valueVarName t env'
        unless (Map.member u qmap) $ addQuals u (tq env'' (Var (toSort baseT) valueVarName) (allScalars env'))
      _ -> return ()
processConstraint (WellFormedCond env (Unknown _ u))
  = do
      tass <- use typeAssignment
      cq <- asks _condQualsGen
      let env' = typeSubstituteEnv tass env
      addQuals u (cq env' (allScalars env'))
processConstraint (WellFormedMatchCond env (Unknown _ u))
  = do
      tass <- use typeAssignment
      mq <- asks _matchQualsGen
      let env' = typeSubstituteEnv tass env
      addQuals u (mq env' (allPotentialScrutinees env'))
processConstraint (SharedType env var (ScalarT base fml pot) (ScalarT baseL fmlL potL) (ScalarT baseR fmlR potR)) 
  | equalShape base baseL && equalShape baseL baseR = do 
  tass <- use typeAssignment
  pass <- use predAssignment
  let env' = typeSubstituteEnv tass env
      subst = sortSubstituteFml (asSortSubst tass) . substitutePredicate pass
      fml' = subst fml
      fmlL' = subst fmlL
      fmlR' = subst fmlR
      pot' = subst pot
      potL' = subst potL
      potR' = subst potR
  simpleConstraints %= (SharedType env var (ScalarT base fml' pot') (ScalarT baseL fmlL' potL') (ScalarT baseR fmlR' potR') :)
processConstraint SharedType{} = return ()
processConstraint c = error $ show $ text "processConstraint: not a simple constraint" <+> pretty c

generateHornClauses :: (MonadHorn s, MonadSMT s) => Constraint -> TCSolver s ()
generateHornClauses c@(Subtype env (ScalarT baseTL l potl) (ScalarT baseTR r potr) False label) | equalShape baseTL baseTR
  = do
      emb <- embedEnv env (l |&| r) True
      clauses <- lift . lift . lift $ preprocessConstraint (conjunction (Set.insert l emb) |=>| r)
      hornClauses %= (zip clauses (repeat label) ++)
generateHornClauses (Subtype env (ScalarT baseTL l potl) (ScalarT baseTR r potr) True _) | equalShape baseTL baseTR
  = do
      emb <- embedEnv env (l |&| r) False
      let clause = conjunction (Set.insert l $ Set.insert r emb)
      consistencyChecks %= (clause :)
generateHornClauses c@(SharedType var env (ScalarT base fml pot) (ScalarT baseL fmlL potL) (ScalarT baseR fmlR potR)) = return ()
  -- error $ show $ text "generateHornClauses: nothing to do for type splitting constraint" <+> pretty c
generateHornClauses c = error $ show $ text "generateHornClauses: not a simple subtyping constraint" <+> pretty c

-- | 'allScalars' @env@ : logic terms for all scalar symbols in @env@
-- TODO: do something with potentials?
allScalars :: Environment -> [Formula]
allScalars env = mapMaybe toFormula $ Map.toList $ symbolsOfArity 0 env
  where
    toFormula (_, ForallT _ _) = Nothing
    toFormula (x, _) | x `Set.member` (env ^. letBound) = Nothing
    toFormula (x, Monotype t) = case t of
      ScalarT IntT  (Binary Eq _ (IntLit n)) _ -> Just $ IntLit n
      ScalarT BoolT (Var _ _) _ -> Just $ BoolLit True
      ScalarT BoolT (Unary Not (Var _ _)) _ -> Just $ BoolLit False
      ScalarT (DatatypeT dt [] []) (Binary Eq _ cons@(Cons _ name [])) _ | x == name -> Just cons
      ScalarT b _ _ -> Just $ Var (toSort b) x
      _ -> Nothing

-- | 'allPotentialScrutinees' @env@ : logic terms for all scalar symbols in @env@
allPotentialScrutinees :: Environment -> [Formula]
allPotentialScrutinees env = mapMaybe toFormula $ Map.toList $ symbolsOfArity 0 env
  where
    toFormula (x, Monotype t) = case t of
      ScalarT b@(DatatypeT _ _ _) _ _ ->
        if Set.member x (env ^. unfoldedVars) && notElem (Program (PSymbol x) t) (env ^. usedScrutinees)
          then Just $ Var (toSort b) x
          else Nothing
      _ -> Nothing
    toFormula _ = Nothing

hasPotentialScrutinees :: Monad s => Environment -> TCSolver s Bool
hasPotentialScrutinees env = do
  tass <- use typeAssignment
  return $ not $ null $ allPotentialScrutinees (typeSubstituteEnv tass env)



addTypeAssignment tv t = typeAssignment %= Map.insert tv t
addPredAssignment p fml = predAssignment %= Map.insert p fml

addQuals :: MonadHorn s => Id -> QSpace -> TCSolver s ()
addQuals name quals = do
  quals' <- lift . lift . lift $ pruneQualifiers quals
  qualifierMap %= Map.insert name quals'

-- | Add unknown @name@ with valuation @valuation@ to solutions of all candidates
addFixedUnknown :: MonadHorn s => Id -> Set Formula -> TCSolver s ()
addFixedUnknown name valuation = do
    addQuals name (toSpace Nothing (Set.toList valuation))
    candidates %= map update
  where
    update cand = cand { solution = Map.insert name valuation (solution cand) }

-- | 'fresh' @t@ : a type with the same shape as @t@ but fresh type variables, fresh predicate variables, and fresh unknowns as refinements
fresh :: Monad s => Environment -> RType -> TCSolver s RType
fresh env (ScalarT (TypeVarT vSubst a m) _ p) | not (isBound env a) = do
  -- Free type variable: replace with fresh free type variable
  a' <- freshId "A"
  return $ ScalarT (TypeVarT vSubst a' m) ftrue p
fresh env (ScalarT baseT _ p) = do
  baseT' <- freshBase baseT
  -- Replace refinement with fresh predicate unknown:
  k <- freshId "U"
  return $ ScalarT baseT' (Unknown Map.empty k) p
  where
    freshBase (DatatypeT name tArgs _) = do
      -- Replace type arguments with fresh types:
      tArgs' <- mapM (fresh env) tArgs
      -- Replace predicate arguments with fresh predicate variables:
      let (DatatypeDef tParams pParams _ _ _) = (env ^. datatypes) Map.! name
      pArgs' <- mapM (\sig -> freshPred env . map (noncaptureSortSubst tParams (map (toSort . baseTypeOf) tArgs')) . predSigArgSorts $ sig) pParams
      return $ DatatypeT name tArgs' pArgs'
    -- Ensure fresh base type has multiplicity 1 to avoid zeroing other formulas during unification
    --freshBase (TypeVarT subs a m) = return $ TypeVarT subs a defMultiplicity
    freshBase baseT = return baseT
fresh env (FunctionT x tArg tFun c) = 
  liftM2 (\t r -> FunctionT x t r c) (fresh env tArg) (fresh env tFun)
fresh env t = let (env', t') = embedContext env t in fresh env' t'


freshPred env sorts = do
  p' <- freshId "P"
  modify $ addTypingConstraint (WellFormedPredicate env sorts p')
  let args = zipWith Var sorts deBrujns
  return $ Pred BoolS p' args

-- | Set valuation of unknown @name@ to @valuation@
-- and re-check all potentially affected constraints in all candidates
setUnknownRecheck :: MonadHorn s => Id -> Set Formula -> Set Id -> TCSolver s ()
setUnknownRecheck name valuation duals = do
  writeLog 3 $ text "Re-checking candidates after updating" <+> text name
  cands@(cand:_) <- use candidates
  let clauses = Set.filter (\fml -> name `Set.member` (Set.map unknownName (unknownsOf fml))) (validConstraints cand) -- First candidate cannot have invalid constraints
  let cands' = map (\c -> c { solution = Map.insert name valuation (solution c) }) cands
  env <- use initEnv
  cands'' <- lift . lift . lift $ checkCandidates False (Set.toList clauses) (instantiateConsAxioms env Nothing) cands'

  if null cands''
    then throwError $ text "Re-checking candidates failed"
    else do
      let liveClauses = Set.filter (\fml -> duals `disjoint` (Set.map unknownName (unknownsOf fml))) (validConstraints cand)
      candidates .= map (\c -> c {
                                  validConstraints = Set.intersection liveClauses (validConstraints c),
                                  invalidConstraints = Set.intersection liveClauses (invalidConstraints c) }) cands'' -- Remove Horn clauses produced by now eliminated code

-- | 'instantiateConsAxioms' @env fml@ : If @fml@ contains constructor applications, return the set of instantiations of constructor axioms for those applications in the environment @env@
instantiateConsAxioms :: Environment -> Maybe Formula -> Formula -> Set Formula
instantiateConsAxioms env mVal fml = let inst = instantiateConsAxioms env mVal in  
  case fml of
    Cons resS@(DataS dtName _) ctor args -> Set.unions $ Set.fromList (map (measureAxiom resS ctor args) (Map.elems $ allMeasuresOf dtName env)) :
                                                         map (instantiateConsAxioms env Nothing) args
    Unary op e -> inst e
    Binary op e1 e2 -> inst e1 `Set.union` inst e2
    Ite e0 e1 e2 -> inst e0 `Set.union` inst e1 `Set.union` inst e2
    SetLit _ elems -> Set.unions (map inst elems)
    Pred _ p args -> Set.unions $ map inst args
    _ -> Set.empty
  where
    measureAxiom resS ctor args (MeasureDef inSort _ defs constantArgs _) =
      let
        MeasureCase _ vars body = head $ filter (\(MeasureCase c _ _) -> c == ctor) defs
        sParams = map varSortName (sortArgsOf inSort) -- sort parameters in the datatype declaration
        sArgs = sortArgsOf resS -- actual sort argument in the constructor application
        body' = noncaptureSortSubstFml sParams sArgs body -- measure definition with actual sorts for all subexpressions
        newValue = fromMaybe (Cons resS ctor args) mVal
        constArgNames = fmap fst constantArgs
        prefixes = fmap (++ "D") constArgNames 
        constVars = zipWith (somewhatFreshVar env) prefixes (fmap snd constantArgs)
        subst = Map.fromList $ (valueVarName, newValue) : zip vars args ++ zip constArgNames constVars-- substitute formals for actuals and constructor application or provided value for _v
        wrapForall xs f = foldl (flip All) f xs
        qBody = wrapForall constVars body'
      in substitute subst qBody

-- | 'matchConsType' @formal@ @actual@ : unify constructor return type @formal@ with @actual@
matchConsType formal@(ScalarT (DatatypeT d vars pVars) _ _) actual@(ScalarT (DatatypeT d' args pArgs) _ p) | d == d'
  = do
      writeLog 3 $ text "Matching constructor type" $+$ pretty formal $+$ text "with scrutinee" $+$ pretty actual
      zipWithM_ (\(ScalarT (TypeVarT _ a _) ftrue _) t -> addTypeAssignment a t) vars args
      zipWithM_ (\(Pred BoolS p _) fml -> addPredAssignment p fml) pVars pArgs
matchConsType t t' = error $ show $ text "matchConsType: cannot match" <+> pretty t <+> text "against" <+> pretty t'

currentAssignment :: Monad s => RType -> TCSolver s RType
currentAssignment t = do
  tass <- use typeAssignment
  return $ typeSubstitute tass t

-- | Substitute type variables, predicate variables, and predicate unknowns in @t@
-- using current type assignment, predicate assignment, and liquid assignment
finalizeType :: Monad s => RType -> TCSolver s RType
finalizeType t = do
  tass <- use typeAssignment
  pass <- use predAssignment
  sol <- uses candidates (solution . head)
  return $ (typeApplySolution sol . typeSubstitutePred pass . typeSubstitute tass) t

-- | Substitute type variables, predicate variables, and predicate unknowns in @p@
-- using current type assignment, predicate assignment, and liquid assignment
finalizeProgram :: Monad s => RProgram -> TCSolver s (RProgram, TypingState) 
finalizeProgram p = do
  tass <- use typeAssignment
  pass <- use predAssignment
  sol <- uses candidates (solution . head)
  tstate <- get
  let prog = (typeApplySolution sol . typeSubstitutePred pass . typeSubstitute tass) <$> p
  return (prog, tstate)