// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {LinkTokenInterface} from "@chainlink/contracts/src/v0.8/interfaces/LinkTokenInterface.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {CCIPDirectory} from "./CCIPDirectory.sol";
import {TrustedSender} from "./TrustedSender.sol";

error UnauthorizedChainSelector();

abstract contract Multihop is CCIPDirectory, CCIPReceiver , TrustedSender {

    uint64 immutable public chainIdThis;

    constructor (uint64 _chainIdThis, address _router) CCIPReceiver(_router){
        CrossChainMetadataAddress memory _metadata = getConfigFromNetwork(_chainIdThis);

        chainIdThis = _chainIdThis;

        LinkTokenInterface(_metadata.linkToken).approve(_metadata.ccipRouter, type(uint256).max);
    }
    /****************************************************************/
    /********************** Encode & Decode *************************/
    /****************************************************************/

    // function _encodeAppMessage(bytes4 selector, bytes data) internal virtual;

    function _decodeAppMessage(bytes[] memory encodedMessage) internal virtual;


    /****************************************************************/
    /********************** Execute or Forward **********************/
    /****************************************************************/

    function _executeAndForwardMessage(uint64[] memory bestRoutes , bytes[] memory encodedMessage) internal {
        // remove first array bestRoutes to determine the destination
        uint64[] memory newBestRoutes = new uint64[](bestRoutes.length - 1);
        for(uint256 i = 0; i < bestRoutes.length - 1; i++){
            newBestRoutes[i] = bestRoutes[i+1];
        }

        // Check if already at destination
        if(newBestRoutes.length > 0){
            bytes memory data = abi.encode(newBestRoutes,encodedMessage);

            // Send message
            uint64 chainIdNext = newBestRoutes[0];

            _sendMessage(chainIdNext, data);

        }else{
            _decodeAppMessage(encodedMessage);
        }
    }

    function _sendMessage(
        uint64 chainIdNext,
        bytes memory data
    ) internal returns (bytes32 messageId) {
        // Get Router and Link
        CrossChainMetadataAddress memory _metadataChainThis = getConfigFromNetwork(chainIdThis);
        CrossChainMetadataAddress memory _metadataChainNext = getConfigFromNetwork(chainIdNext);

        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        Client.EVM2AnyMessage memory ccipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(_metadataChainNext.crossChainApp), // ABI encode next bestRoutes address
            data: data, // ABI encode message
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: "",
            feeToken: _metadataChainThis.linkToken // Setting feeToken to $LINK, as main currency for fee
        });

        // Send Messages
        messageId = IRouterClient(_metadataChainThis.ccipRouter).ccipSend(
            chainIdNext,
            ccipMessage
        );

        return messageId;
    }

    function _ccipReceive(
        Client.Any2EVMMessage memory message
    ) internal override{
        uint64 sourceChainSelector = message.sourceChainSelector; // fetch the source chain identifier (aka selector)
        address sender = abi.decode(message.sender, (address)); // abi-decoding of the sender address

        // Trusted Sender check
        if (!isTrustedSender(sourceChainSelector,sender)) {
            revert UnauthorizedChainSelector();
        }
        
        (uint64[] memory bestRoutes , bytes[] memory encodedMessage) = abi.decode(message.data,(uint64[], bytes[]));
        
        _executeAndForwardMessage(bestRoutes,encodedMessage);

    }

    
}