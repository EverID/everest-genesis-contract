pragma solidity 0.6.4;

import "./interface/IApplication.sol";
import "./interface/ICrossChain.sol";
import "./interface/ILightClient.sol";
import "./interface/IRelayerIncentivize.sol";
import "./interface/IRelayerHub.sol";
import "./lib/Memory.sol";
import "./lib/BytesToTypes.sol";
import "./interface/IParamSubscriber.sol";
import "./System.sol";
import "./MerkleProof.sol";


contract CrossChain is System, ICrossChain, IParamSubscriber{

  // constant variables
  string constant public STORE_NAME = "ibc";
  uint256 constant public CROSS_CHAIN_KEY_PREFIX = 0x01006000; // last 6 bytes
  uint8 constant public SYN_PACKAGE = 0x00;
  uint8 constant public ACK_PACKAGE = 0x01;
  uint8 constant public FAIL_ACK_PACKAGE = 0x02;
  uint256 constant public INIT_BATCH_SIZE = 50;

  // governable parameters
  uint256 public batchSizeForOracle;

  //state variables
  uint256 public previousTxHeight;
  uint256 public txCounter;
  int64 public oracleSequence;
  mapping(uint8 => address) public channelHandlerContractMap;
  mapping(address => mapping(uint8 => bool))public registeredContractChannelMap;
  mapping(uint8 => uint64) public channelSendSequenceMap;
  mapping(uint8 => uint64) public channelReceiveSequenceMap;
  mapping(uint8 => bool) public isRelayRewardFromSystemReward;

  // event
  event crossChainPackage(uint16 chainId, uint64 indexed oracleSequence, uint64 indexed packageSequence, uint8 indexed channelId, bytes payload);
  event receivedPackage(uint8 packageType, uint64 indexed packageSequence, uint8 indexed channelId);
  event unsupportedPackage(uint64 indexed packageSequence, uint8 indexed channelId, bytes payload);
  event unexpectedRevertInPackageHandler(address indexed contractAddr, string reason);
  event unexpectedFailureAssertionInPackageHandler(address indexed contractAddr, bytes lowLevelData);
  event paramChange(string key, bytes value);
  event enableOrDisableChannel(uint8 indexed channelId, bool isEnable);
  event addChannel(uint8 indexed channelId, address indexed contractAddr);

  modifier sequenceInOrder(uint64 _sequence, uint8 _channelID) {
    uint64 expectedSequence = channelReceiveSequenceMap[_channelID];
    require(_sequence == expectedSequence, "sequence not in order");

    channelReceiveSequenceMap[_channelID]=expectedSequence+1;
    _;
  }

  modifier blockSynced(uint64 _height) {
    require(ILightClient(LIGHT_CLIENT_ADDR).isHeaderSynced(_height), "light client not sync the block yet");
    _;
  }

  modifier channelSupported(uint8 _channelID) {
    require(channelHandlerContractMap[_channelID]!=address(0x0), "channel is not supported");
    _;
  }

  modifier onlyRegisteredContractChannel(uint8 channleId) {
    require(registeredContractChannelMap[msg.sender][channleId], "the contract and channel have not been registered");
    _;
  }

  // | length   | prefix | sourceChainID| destinationChainID | channelID | sequence |
  // | 32 bytes | 1 byte | 2 bytes      | 2 bytes            |  1 bytes  | 8 bytes  |
  function generateKey(uint64 _sequence, uint8 _channelID) internal pure returns(bytes memory) {
    uint256 fullCROSS_CHAIN_KEY_PREFIX = CROSS_CHAIN_KEY_PREFIX | _channelID;
    bytes memory key = new bytes(14);

    uint256 ptr;
    assembly {
      ptr := add(key, 14)
    }
    assembly {
      mstore(ptr, _sequence)
    }
    ptr -= 8;
    assembly {
      mstore(ptr, fullCROSS_CHAIN_KEY_PREFIX)
    }
    ptr -= 6;
    assembly {
      mstore(ptr, 14)
    }
    return key;
  }

  function init() external onlyNotInit {
    channelHandlerContractMap[BIND_CHANNELID] = TOKEN_MANAGER_ADDR;
    isRelayRewardFromSystemReward[BIND_CHANNELID] = false;
    registeredContractChannelMap[TOKEN_MANAGER_ADDR][BIND_CHANNELID] = true;

    channelHandlerContractMap[TRANSFER_IN_CHANNELID] = TOKEN_HUB_ADDR;
    isRelayRewardFromSystemReward[TRANSFER_IN_CHANNELID] = false;
    registeredContractChannelMap[TOKEN_HUB_ADDR][TRANSFER_IN_CHANNELID] = true;

    channelHandlerContractMap[TRANSFER_OUT_CHANNELID] = TOKEN_HUB_ADDR;
    isRelayRewardFromSystemReward[TRANSFER_OUT_CHANNELID] = false;
    registeredContractChannelMap[TOKEN_HUB_ADDR][TRANSFER_OUT_CHANNELID] = true;


    channelHandlerContractMap[STAKING_CHANNELID] = VALIDATOR_CONTRACT_ADDR;
    isRelayRewardFromSystemReward[STAKING_CHANNELID] = true;
    registeredContractChannelMap[VALIDATOR_CONTRACT_ADDR][STAKING_CHANNELID] = true;

    channelHandlerContractMap[GOV_CHANNELID] = GOV_HUB_ADDR;
    isRelayRewardFromSystemReward[GOV_CHANNELID] = true;
    registeredContractChannelMap[GOV_HUB_ADDR][GOV_CHANNELID] = true;

    channelHandlerContractMap[SLASH_CHANNELID] = SLASH_CONTRACT_ADDR;
    isRelayRewardFromSystemReward[SLASH_CHANNELID] = true;
    registeredContractChannelMap[SLASH_CONTRACT_ADDR][SLASH_CHANNELID] = true;

    batchSizeForOracle = INIT_BATCH_SIZE;

    oracleSequence = -1;
    previousTxHeight = 0;
    txCounter = 0;

    alreadyInit=true;
  }

function encodePayload(uint8 packageType, uint256 relayFee, bytes memory msgBytes) public pure returns(bytes memory) {
    uint256 payloadLength = msgBytes.length + 33;
    bytes memory payload = new bytes(payloadLength);
    uint256 ptr;
    assembly {
      ptr := payload
    }
    ptr+=33;

    assembly {
      mstore(ptr, relayFee)
    }

    ptr-=32;
    assembly {
      mstore(ptr, packageType)
    }

    ptr-=1;
    assembly {
      mstore(ptr, payloadLength)
    }

    ptr+=65;
    (uint256 src,) = Memory.fromBytes(msgBytes);
    Memory.copy(src, ptr, msgBytes.length);

    return payload;
  }

  // | type   | relayFee   |package  |
  // | 1 byte | 32 bytes   | bytes    |
  function decodePayloadHeader(bytes memory payload) internal pure returns(bool, uint8, uint256, bytes memory) {
    if (payload.length < 33) {
      return (false, 0, 0, new bytes(0));
    }

    uint256 ptr;
    assembly {
      ptr := payload
    }

    uint8 packageType;
    ptr+=1;
    assembly {
      packageType := mload(ptr)
    }

    uint256 relayFee;
    ptr+=32;
    assembly {
      relayFee := mload(ptr)
    }

    ptr+=32;
    bytes memory msgBytes = new bytes(payload.length-33);
    (uint256 dst, ) = Memory.fromBytes(msgBytes);
    Memory.copy(ptr, dst, payload.length-33);

    return (true, packageType, relayFee, msgBytes);
  }

  function handlePackage(bytes calldata payload, bytes calldata proof, uint64 height, uint64 packageSequence, uint8 channelId) onlyInit onlyRelayer
      sequenceInOrder(packageSequence, channelId) /*blockSynced(height)*/ channelSupported(channelId) external {
    bytes memory payloadLocal = payload; // fix error: stack too deep, try removing local variables
   // bytes memory proofLocal = proof; // fix error: stack too deep, try removing local variables
   // require(MerkleProof.validateMerkleProof(ILightClient(LIGHT_CLIENT_ADDR).getAppHash(height), STORE_NAME, generateKey(packageSequence, channelId), payloadLocal, proofLocal), "invalid merkle proof");

    address payable headerRelayer = ILightClient(LIGHT_CLIENT_ADDR).getSubmitter(height);

    uint8 channelIdLocal = channelId; // fix error: stack too deep, try removing local variables
    (bool success, uint8 packageType, uint256 relayFee, bytes memory msgBytes) = decodePayloadHeader(payloadLocal);
    if (!success) {
      emit unsupportedPackage(packageSequence, channelIdLocal, payloadLocal);
      return;
    }
    emit receivedPackage(packageType, packageSequence, channelIdLocal);
    if (packageType == SYN_PACKAGE) {
      address handlerContract = channelHandlerContractMap[channelIdLocal];
      try IApplication(handlerContract).handleSynPackage(channelIdLocal, msgBytes) returns (bytes memory responsePayload) {
        if (responsePayload.length!=0) {
          sendPackage(channelSendSequenceMap[channelIdLocal], channelIdLocal, encodePayload(ACK_PACKAGE, 0, responsePayload));
          channelSendSequenceMap[channelIdLocal] = channelSendSequenceMap[channelIdLocal] + 1;
        }
      } catch Error(string memory reason) {
        sendPackage(channelSendSequenceMap[channelIdLocal], channelIdLocal, encodePayload(FAIL_ACK_PACKAGE, 0, msgBytes));
        channelSendSequenceMap[channelIdLocal] = channelSendSequenceMap[channelIdLocal] + 1;
        emit unexpectedRevertInPackageHandler(handlerContract, reason);
      } catch (bytes memory lowLevelData) {
        sendPackage(channelSendSequenceMap[channelIdLocal], channelIdLocal, encodePayload(FAIL_ACK_PACKAGE, 0, msgBytes));
        channelSendSequenceMap[channelIdLocal] = channelSendSequenceMap[channelIdLocal] + 1;
        emit unexpectedFailureAssertionInPackageHandler(handlerContract, lowLevelData);
      }
    } else if (packageType == ACK_PACKAGE) {
      address handlerContract = channelHandlerContractMap[channelIdLocal];
      try IApplication(handlerContract).handleAckPackage(channelIdLocal, msgBytes) {
      } catch Error(string memory reason) {
        emit unexpectedRevertInPackageHandler(handlerContract, reason);
      } catch (bytes memory lowLevelData) {
        emit unexpectedFailureAssertionInPackageHandler(handlerContract, lowLevelData);
      }
    } else if (packageType == FAIL_ACK_PACKAGE) {
      address handlerContract = channelHandlerContractMap[channelIdLocal];
      try IApplication(handlerContract).handleFailAckPackage(channelIdLocal, msgBytes) {
      } catch Error(string memory reason) {
        emit unexpectedRevertInPackageHandler(handlerContract, reason);
      } catch (bytes memory lowLevelData) {
        emit unexpectedFailureAssertionInPackageHandler(handlerContract, lowLevelData);
      }
    }
    IRelayerIncentivize(INCENTIVIZE_ADDR).addReward(headerRelayer, msg.sender, relayFee, isRelayRewardFromSystemReward[channelIdLocal] || packageType != SYN_PACKAGE);
  }

  function sendPackage(uint64 packageSequence, uint8 channelId, bytes memory payload) internal {
    if (block.number > previousTxHeight) {
      oracleSequence++;
      txCounter = 1;
      previousTxHeight=block.number;
    } else {
      txCounter++;
      if (txCounter>batchSizeForOracle) {
        oracleSequence++;
        txCounter = 1;
      }
    }
    emit crossChainPackage(bscChainID, uint64(oracleSequence), packageSequence, channelId, payload);
  }

  function sendSynPackage(uint8 channelId, bytes calldata msgBytes, uint256 relayFee) onlyInit onlyRegisteredContractChannel(channelId) external override {
    uint64 sendSequence = channelSendSequenceMap[channelId];
    sendPackage(sendSequence, channelId, encodePayload(SYN_PACKAGE, relayFee, msgBytes));
    sendSequence++;
    channelSendSequenceMap[channelId] = sendSequence;
  }

  function updateParam(string calldata key, bytes calldata value) onlyGov external override {
    if (Memory.compareStrings(key, "batchSizeForOracle")) {
      uint256 newBatchSizeForOracle = BytesToTypes.bytesToUint256(32, value);
      require(newBatchSizeForOracle <= 10000 && newBatchSizeForOracle >= 10, "the newBatchSizeForOracle should be in [10, 10000]");
      batchSizeForOracle = newBatchSizeForOracle;
    } else if (Memory.compareStrings(key, "addOrUpdateChannel")) {
      bytes memory valueLocal = value;
      require(valueLocal.length == 22, "length of value for addOrUpdateChannel should be 22, channelId:isFromSystem:handlerAddress");
      uint8 channelId;
      assembly {
        channelId := mload(add(valueLocal, 1))
      }

      uint8 rewardConfig;
      assembly {
        rewardConfig := mload(add(valueLocal, 2))
      }
      bool isRewardFromSystem = (rewardConfig == 0x0);

      address handlerContract;
      assembly {
        handlerContract := mload(add(valueLocal, 22))
      }

      require(isContract(handlerContract), "address is not a contract");
      channelHandlerContractMap[channelId]=handlerContract;
      registeredContractChannelMap[handlerContract][channelId] = true;
      isRelayRewardFromSystemReward[channelId] = isRewardFromSystem;
      emit addChannel(channelId, handlerContract);
    } else if (Memory.compareStrings(key, "enableOrDisableChannel")) {
      bytes memory valueLocal = value;
      require(valueLocal.length == 2, "length of value for enableOrDisableChannel should be 2, channelId:isEnable");

      uint8 channelId;
      assembly {
        channelId := mload(add(valueLocal, 1))
      }
      uint8 status;
      assembly {
        status := mload(add(valueLocal, 2))
      }
      bool isEnable = (status == 1);

      address handlerContract = channelHandlerContractMap[channelId];
      if (handlerContract != address(0x00)) { //channel existing
        registeredContractChannelMap[handlerContract][channelId] = isEnable;
        emit enableOrDisableChannel(channelId, isEnable);
      }
    } else {
      require(false, "unknown param");
    }
    emit paramChange(key, value);
  }
}