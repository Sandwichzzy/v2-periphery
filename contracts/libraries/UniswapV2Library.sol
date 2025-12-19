pragma solidity >=0.5.0;

import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";

import "./SafeMath.sol";

library UniswapV2Library {
    using SafeMath for uint256;

    // returns sorted token addresses, used to handle return values from pairs sorted in this order
    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        require(tokenA != tokenB, "UniswapV2Library: IDENTICAL_ADDRESSES");
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "UniswapV2Library: ZERO_ADDRESS");
    }

    // calculates the CREATE2 address for a pair without making any external calls
    function pairFor(address factory, address tokenA, address tokenB) internal pure returns (address pair) {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        pair = address(
            uint256(
                keccak256(
                    abi.encodePacked(
                        hex"ff",
                        factory,
                        //NOTE: salt = keccak256(abi.encodePacked(token0, token1))
                        keccak256(abi.encodePacked(token0, token1)),
                        //NOTE: init code hash = keccak256(creation bytecode)
                        hex"96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f" // init code hash
                    )
                )
            )
        );
    }

    // fetches and sorts the reserves for a pair
    // Uniswap V2中，每个交易对（pair）由两个代币组成，但是存储时按照地址排序
    // 如果 token0 和 token1 的顺序不固定，同一个代币对就会有多个可能的地址。
    // 将地址较小的作为token0，较大的作为token1。
    // 这样做的目的是为了确保在合约中处理两个代币时，顺序是确定的，避免因为传入顺序不同而导致错误。
    function getReserves(address factory, address tokenA, address tokenB)
        internal
        view
        returns (uint256 reserveA, uint256 reserveB)
    {
        //NOTE:  先排序确定token0和token1
        (address token0,) = sortTokens(tokenA, tokenB);
        //NOTE:  获取交易对储备（储备量是按token0,token1顺序存储的）
        (uint256 reserve0, uint256 reserve1,) = IUniswapV2Pair(pairFor(factory, tokenA, tokenB)).getReserves();
        //NOTE:  将储备量映射回原始的tokenA,tokenB顺序
        (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    // given some amount of an asset and pair reserves, returns an equivalent amount of the other asset
    // NOTE: 保证添加流动性后，price不变
    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) internal pure returns (uint256 amountB) {
        require(amountA > 0, "UniswapV2Library: INSUFFICIENT_AMOUNT");
        require(reserveA > 0 && reserveB > 0, "UniswapV2Library: INSUFFICIENT_LIQUIDITY");
        //NOTE:
        // dy/dx = y0/x0
        // dy = dx * y0 / x0
        amountB = amountA.mul(reserveB) / reserveA;
    }

    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountOut)
    {
        require(amountIn > 0, "UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "UniswapV2Library: INSUFFICIENT_LIQUIDITY");
        //NOTE:
        //x =token in
        //y =token out
        //      dx*0.997 *y0
        // dy= --------------
        //      x0+dx*0.997

        //NOTE:
        // dx*997
        uint256 amountInWithFee = amountIn.mul(997);
        // dx*997 * y0
        uint256 numerator = amountInWithFee.mul(reserveOut);
        // x0*1000 + dx*997
        uint256 denominator = reserveIn.mul(1000).add(amountInWithFee);
        //      dx*0.997 *y0
        // dy= --------------
        //      x0+dx*0.997
        amountOut = numerator / denominator;
    }

    // given an output amount of an asset and pair reserves, returns a required input amount of the other asset
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountIn)
    {
        require(amountOut > 0, "UniswapV2Library: INSUFFICIENT_OUTPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "UniswapV2Library: INSUFFICIENT_LIQUIDITY");
        //NOTE:
        //dx =token in
        //dy =token out
        //x0 = reserve in
        //y0 = reserve out

        // (x0+dx(1-f))(y0 - dy) = x0*y0
        // x0*y0 - x0*dy + dx(1-f)*y0- dx*dy(1-f) = x0*y0
        // dx(1-f)*y0 - dx*dy(1-f) = x0*dy
        // dx((1-f)*y0 - dy(1-f)) = x0*dy
        // dx(1-f)(y0 - dy) = x0*dy
        //       x0*dy               1
        // dx= -------------- * --------
        //     (y0 - dy)         (1-f)

        // x0*dy*1000
        uint256 numerator = reserveIn.mul(amountOut).mul(1000);
        // (y0 - dy)*997
        uint256 denominator = reserveOut.sub(amountOut).mul(997);
        // NOTE:round up
        //     x0*dy*1000
        // dx= --------------
        //     (y0 - dy)*997
        amountIn = (numerator / denominator).add(1);
    }

    // performs chained getAmountOut calculations on any number of pairs
    // NOTE: get output amounts for specified input amounts
    function getAmountsOut(address factory, uint256 amountIn, address[] memory path)
        internal
        view
        returns (uint256[] memory amounts)
    {
        require(path.length >= 2, "UniswapV2Library: INVALID_PATH");
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        //NOTE:

        // i | input amount  | output amount
        // 0 | path[0]   | path[1]
        // 1 | path[1]   | path[2]
        // 2 | path[2]   | path[3]
        //n-2| path[n-2] | path[n-1]
        for (uint256 i; i < path.length - 1; i++) {
            //NOTE: reserves = internal balance of tokens inside pair contract
            (uint256 reserveIn, uint256 reserveOut) = getReserves(factory, path[i], path[i + 1]);
            //NOTE: use the previous output for input
            amounts[i + 1] = getAmountOut(amounts[i], reserveIn, reserveOut);

            //NOTE:examples
            //path=[DAI,WETH]
            //amounts[0]=1000*10**18 DAI
            //amounts[1]=WETH amount out

            //path=[DAI,WETH,MKR]
            //amounts[0]=1000*10**18 DAI
            //amounts[1]=WETH amount out
            //amounts[2]=MKR amount out
        }
    }

    // performs chained getAmountIn calculations on any number of pairs
    // NOTE: get input amounts for specified output amounts
    function getAmountsIn(address factory, uint256 amountOut, address[] memory path)
        internal
        view
        returns (uint256[] memory amounts)
    {
        require(path.length >= 2, "UniswapV2Library: INVALID_PATH");
        amounts = new uint256[](path.length);
        amounts[amounts.length - 1] = amountOut;

        // --- Inputs ---
        // amountOut = 1e18
        // path = [WETH, DAI, MKR]
        // --- Outputs ---
        // WETH     804555560756014274 (0.8045... * 1e18)
        // DAI  2011892163724115442026 (2011.892... * 1e18)
        // MKR     1000000000000000000 (1 * 1e18)
        // --- Execution ---
        // amounts = [0, 0, 0]
        // amounts = [0, 0, 1000000000000000000]

        // For loop
        // i = 2
        // path[i - 1] = DAI, path[i] = MKR
        // amounts[i] = 1000000000000000000
        // amounts[i - 1] = 2011892163724115442026
        // amounts = [0, 2011892163724115442026, 1000000000000000000]
        // i = 1
        // path[i - 1] = WETH, path[i] = DAI
        // amounts[i] = 2011892163724115442026
        // amounts[i - 1] = 804555560756014274
        // amounts = [804555560756014274, 2011892163724115442026, 1000000000000000000]

        // NOTE:
        //   i | output amount | input amount
        // n-1 | amounts[n-1] | amounts[n-2]
        // n-2 | amounts[n-2] | amounts[n-3]
        // ...
        //   2 | amounts[2]   | amounts[1]
        //   1 | amounts[1]   | amounts[0]

        for (uint256 i = path.length - 1; i > 0; i--) {
            (uint256 reserveIn, uint256 reserveOut) = getReserves(factory, path[i - 1], path[i]);
            amounts[i - 1] = getAmountIn(amounts[i], reserveIn, reserveOut);
        }
    }
}
