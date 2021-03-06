{-# LANGUAGE DeriveAnyClass  #-}
{-# LANGUAGE DeriveGeneric   #-}
{-# LANGUAGE TemplateHaskell #-}

-- | Strategy-related data types and functions/helpers.

module RSCoin.Core.Strategy
     ( AddressToTxStrategyMap
     , AllocationAddress  (..)
     , AllocationInfo     (..)
     , AllocationStrategy (..)
     , MSAddress
     , PartyAddress       (..)
     , TxStrategy         (..)

     -- * 'AllocationAddress' lenses and prisms
     , address

      -- * 'AllocationInfo' lenses
     , allocationStrategy
     , currentConfirmations

      -- * 'AllocationStrategy' lenses
     , allParties
     , sigNumber

     -- * Other helpers
     , allocateTxFromAlloc
     , isStrategyCompleted
     , partyToAllocation
     ) where

import           Control.Lens               (makeLenses, traversed, (^..))

import           Data.Binary                (Binary)
import           Data.Binary.Orphans        ()
import           Data.Hashable              (Hashable)
import           Data.HashMap.Strict        (HashMap)
import           Data.HashSet               (HashSet)
import qualified Data.HashSet               as HS hiding (HashSet)
import           Data.Map                   (Map)
import           Data.SafeCopy              (base, deriveSafeCopy)
import           Data.Set                   (Set)
import qualified Data.Set                   as S
import           Data.Text.Buildable        (Buildable (build))
import           GHC.Generics               (Generic)

import           Formatting                 (bprint, int, (%))
import qualified Formatting                 as F (build)

import           Serokell.AcidState         ()
import           Serokell.Util.Text         (listBuilderJSON,
                                             listBuilderJSONIndent)

import           RSCoin.Core.Crypto.Signing (PublicKey, Signature)
import           RSCoin.Core.Primitives     (Address, Transaction)
import           RSCoin.Core.Transaction    (validateSignature)

-- | Type alisas for places where address is used as multisignature address.
type MSAddress = Address

-- | Strategy of confirming transactions.
-- Other strategies are possible, like "getting m out of n, but
-- addresses [A,B,C] must sign". Primitive concept is using M/N.
data TxStrategy
    -- | Strategy of "1 signature per addrid"
    = DefaultStrategy

    -- | Strategy for getting @m@ signatures
    -- out of @length list@, where every signature
    -- should be made by address in list @list@
    | MOfNStrategy Int (S.Set Address)  -- @TODO: replace with HashSet
    deriving (Show, Eq, Generic, Binary)

$(deriveSafeCopy 0 'base ''TxStrategy)

instance Buildable TxStrategy where
    build DefaultStrategy        = "DefaultStrategy"
    build (MOfNStrategy m addrs) = bprint template m (listBuilderJSON addrs)
      where
        template = "TxStrategy {\n" %
                   "  m: "          % int     % "\n" %
                   "  addresses: "  % F.build % "\n" %
                   "}\n"

type AddressToTxStrategyMap = Map Address TxStrategy

-- | This represents party for AllocationStrategy in set of all participants.
data AllocationAddress
    = TrustAlloc { _address :: Address }  -- ^ PublicKey we trust
    | UserAlloc  { _address :: Address }  -- ^ PublicKey of other User
    deriving (Eq, Generic, Hashable, Show, Ord, Binary)

$(deriveSafeCopy 0 'base ''AllocationAddress)
$(makeLenses ''AllocationAddress)

instance Buildable AllocationAddress where
    build (TrustAlloc addr) = bprint ("TrustA : " % F.build) addr
    build (UserAlloc  addr) = bprint ("UserA : "  % F.build) addr

-- | This datatype represents party who sends request to Notary.
data PartyAddress
    = TrustParty
        { partyAddress :: Address    -- ^ Party address of multisig address
        , hotTrustKey  :: PublicKey  -- ^ Hot key which signs ms allocation requests
        }
    | UserParty
        { partyAddress :: Address  -- ^ Same as for 'TrustParty'
        }
    deriving (Eq, Show, Generic, Hashable, Binary)

$(deriveSafeCopy 0 'base ''PartyAddress)

instance Buildable PartyAddress where
    build (TrustParty partyAddr hot) =
        bprint ("TrustP : party = " % F.build % ", master = " % F.build) partyAddr hot
    build (UserParty partyAddr) =
        bprint ("UserP  : " % F.build) partyAddr

-- | Strategy of multisignature address allocation.
-- @TODO: avoid duplication of sets in '_allParties' and '_txStrategy.txParties'
data AllocationStrategy = AllocationStrategy
    { _sigNumber  :: Int                        -- ^ Number of required signatures in transaction
    , _allParties :: Set AllocationAddress  -- ^ 'Set' of all parties for this address
    } deriving (Eq, Show, Generic, Binary)

$(deriveSafeCopy 0 'base ''AllocationStrategy)
$(makeLenses ''AllocationStrategy)

instance Buildable AllocationStrategy where
    build AllocationStrategy{..} = bprint template
        _sigNumber
        (listBuilderJSONIndent 4 _allParties)
      where
        template = "AllocationStrategy {\n"  %
                   "  sigNumber: "  % F.build % "\n" %
                   "  allParties: " % F.build % "\n" %
                   "}\n"

-- | Stores meta information for MS allocation by 'AlocationStrategy'.
data AllocationInfo = AllocationInfo
    { _allocationStrategy   :: AllocationStrategy
    , _currentConfirmations :: HashMap AllocationAddress Address
    } deriving (Eq, Show, Generic, Binary)

$(deriveSafeCopy 0 'base ''AllocationInfo)
$(makeLenses ''AllocationInfo)

instance Buildable AllocationInfo where
    build AllocationInfo{..} = bprint template
        _allocationStrategy
        (listBuilderJSONIndent 4 _currentConfirmations)
      where
        template = "AllocationInfo {\n"   %
                   "  allocationStrategy: "   % F.build % "\n" %
                   "  currentConfirmations: " % F.build % "\n" %
                   "}\n"

-- | Creates corresponding multisignature 'TxStrategy'.
allocateTxFromAlloc :: AllocationStrategy -> TxStrategy
allocateTxFromAlloc AllocationStrategy{..} =
    MOfNStrategy
        _sigNumber $
        S.fromList $ (S.toList _allParties)^..traversed.address

-- | Converts 'PartyAddress' to original 'AllocationAddress'.
partyToAllocation :: PartyAddress -> AllocationAddress
partyToAllocation TrustParty{..} = TrustAlloc partyAddress
partyToAllocation UserParty{..}  = UserAlloc partyAddress

-- | Checks if the inner state of strategy allows us to send
-- transaction and it will be accepted
isStrategyCompleted :: TxStrategy
                    -> Address
                    -> [(Address, Signature Transaction)]
                    -> Transaction
                    -> Bool
isStrategyCompleted DefaultStrategy userAddr signs tx =
    any (\(addr, signature) -> userAddr == addr &&
                         validateSignature signature addr tx) signs
isStrategyCompleted (MOfNStrategy m addresses) _ signs tx =
    let hasSignature userAddr =
            any (\(addr, signature) -> userAddr == addr &&
                                 validateSignature signature addr tx)
                signs
        withSignatures = S.filter hasSignature addresses
    in length withSignatures >= m
