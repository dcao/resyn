{-# LANGUAGE DeriveDataTypeable, StandaloneDeriving #-}

module Main where

import Synquid.Logic
import Synquid.Program
import Synquid.Pretty
import qualified Synquid.Parser as Parser (parseProgram)
import qualified Synquid.Resolver as Resolver (resolveProgramAst)
import Synquid.Solver
import Synquid.Explorer
import Synquid.Synthesizer

import System.Exit
import System.Console.CmdArgs
import Data.Time.Calendar
import Text.ParserCombinators.Parsec (parse, parseFromFile)

programName = "synquid"
versionName = "0.2"
releaseDate = fromGregorian 2015 11 20

-- | Execute or test a Boogie program, according to command-line arguments
main = do
  (CommandLineArgs file appMax scrutineeMax matchMax fix hideScr explicitMatch log_) <- cmdArgs cla
  let explorerParams = defaultExplorerParams { 
    _eGuessDepth = appMax, 
    _scrutineeDepth = scrutineeMax,
    _matchDepth = matchMax,
    _fixStrategy = fix,
    _hideScrutinees = hideScr,
    _abduceScrutinees = not explicitMatch, 
    _explorerLogLevel = log_ 
    }
  let solverParams = defaultSolverParams {
    solverLogLevel = log_
    }
  runOnFile explorerParams solverParams file
  
{- Command line arguments -}

deriving instance Typeable FixpointStrategy
deriving instance Data FixpointStrategy
deriving instance Eq FixpointStrategy
deriving instance Show FixpointStrategy

data CommandLineArgs
    = CommandLineArgs {
        -- | Input
        file :: String,
        -- | Explorer params
        app_max :: Int,
        scrutinee_max :: Int,
        match_max :: Int,
        fix :: FixpointStrategy,
        hide_scrutinees :: Bool,
        explicit_match :: Bool,
        log_ :: Int
      }
  deriving (Data, Typeable, Show, Eq)
  
cla = CommandLineArgs {
  file            = ""              &= typFile &= argPos 0,
  app_max         = 3               &= help ("Maximum depth of an application term (default: 3)"),
  scrutinee_max   = 1               &= help ("Maximum depth of a match scrutinee (default: 0)"),
  match_max       = 2               &= help ("Maximum number of a matches (default: 2)"),
  fix             = AllArguments    &= help (unwords ["What should termination metric for fixpoints be derived from?", show AllArguments, show FirstArgument, show DisableFixpoint, "(default:", show AllArguments, ")"]),
  hide_scrutinees = False           &= help ("Hide scrutinized expressions from the evironment (default: False)"),
  explicit_match  = False           &= help ("Do not abduce match scrutinees (default: False)"),
  log_            = 0               &= help ("Logger verboseness level (default: 0)")      
  } &= help "Synthesize goals specified in the input file" &= program programName &= summary (programName ++ " v" ++ versionName ++ ", " ++ showGregorian releaseDate)

-- | Parameters for template exploration
defaultExplorerParams = ExplorerParams {
  _eGuessDepth = 3,
  _scrutineeDepth = 1,
  _matchDepth = 2,
  _condDepth = 1,
  _fixStrategy = AllArguments,
  _polyRecursion = True,
  _hideScrutinees = False,
  _abduceScrutinees = True,
  _consistencyChecking = False,
  _condQualsGen = undefined,
  _matchQualsGen = undefined,
  _typeQualsGen = undefined,
  _context = id,
  _explorerLogLevel = 1
}

-- | Parameters for constraint solving
defaultSolverParams = SolverParams {
  pruneQuals = True,
  optimalValuationsStrategy = MarcoValuations,    
  semanticPrune = True,
  agressivePrune = True,
  candidatePickStrategy = InitializedWeakCandidate,
  constraintPickStrategy = SmallSpaceConstraint,
  candDoc = const empty,
  solverLogLevel = 1
}

-- | Parse and resolve file, then synthesize the specified goals 
runOnFile :: ExplorerParams -> SolverParams -> String -> IO ()      
runOnFile explorerParams solverParams file = do 
  parseResult <- parseFromFile Parser.parseProgram file
  case parseResult of
    Left parseErr -> (putStr $ show parseErr) >> exitFailure
    -- Right ast -> print $ vsep $ map pretty ast
    Right ast -> case Resolver.resolveProgramAst ast of
      Left resolutionError -> (putStr resolutionError) >> exitFailure
      Right (goals, cquals, tquals) -> mapM_ (synthesizeGoal cquals tquals) goals
  where
    synthesizeGoal cquals tquals goal = do
      print $ text (gName goal) <+> text "::" <+> pretty (gSpec goal)
      -- print empty
      -- print $ vMapDoc pretty pretty (allSymbols $ gEnvironment goal)
      mProg <- synthesize explorerParams solverParams goal cquals tquals
      case mProg of
        Nothing -> putStr "No Solution" >> exitFailure
        Just prog -> print $ text (gName goal) <+> text "=" <+> programDoc (const empty) prog -- $+$ parens (text "Size:" <+> pretty (programNodeCount prog))
      print empty
