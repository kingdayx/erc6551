// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "@openzeppelin/contracts/interfaces/IERC1271.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Burnable.sol";
import "./CBmod.sol";

interface IERC6551Registry {
    function createAccount(
        address implementation,
        bytes32 salt,
        uint256 chainId,
        address tokenContract,
        uint256 tokenId
    ) external returns (address);

    function account(address implementation, bytes32 salt, uint256 chainId, address tokenContract, uint256 tokenId)
        external
        view
        returns (address);
}

interface IERC6551Account {
    function token() external view returns (uint256, address, uint256);
    function state() external view returns (uint256);
    function isValidSigner(address signer, bytes calldata context) external view returns (bytes4);
}

interface IERC6551Executable {
    function execute(address to, uint256 value, bytes calldata data, uint8 operation)
        external
        payable
        returns (bytes memory);
}

contract NFTPackAccount is IERC165, IERC1271, ERC1155Holder, IERC6551Account, IERC6551Executable, Ownable {
    using ECDSA for bytes32;

    struct NFTInfo {
        uint256 nftId;
        uint256 rarityBase;
        uint256 burned;
        bool isERC721;
    }

    address pluginAddress = pluginAddress;
    uint256 public rarityIncreaseFactor;
    uint256 private _stateCounter;
    NFTInfo[] private _nfts;
    IERC1155 private _erc1155;
    mapping(uint256 => IERC721) private _erc721Contracts;

    constructor(address erc1155Address, address _pluginAddress) Ownable() {
        _pluginAddress = pluginAddress;
        rarityIncreaseFactor = 1;
        _nfts.push(NFTInfo(0, 50, 0, false)); // BPP_NFT
        _nfts.push(NFTInfo(1, 30, 0, false)); // NPP_NFT
        _nfts.push(NFTInfo(2, 20, 0, false)); // DRILL_NFT
        _erc1155 = IERC1155(erc1155Address);
    }

    function getBurnedNFTCount(address modularAccountAddress) internal view returns (uint256) {
        return CBNFTBurnTrackingPlugin(pluginAddress).getBurntNFTCount(modularAccountAddress);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(IERC165, ERC1155Receiver)
        returns (bool)
    {
        return interfaceId == type(IERC1271).interfaceId || interfaceId == type(IERC6551Account).interfaceId
            || interfaceId == type(IERC6551Executable).interfaceId || super.supportsInterface(interfaceId);
    }

    function token() public view virtual override returns (uint256, address, uint256) {
        return (block.chainid, address(this), 0);
    }

    function owner() public view virtual override returns (address) {
        (uint256 chainId, address tokenContract, uint256 tokenId) = token();
        if (chainId != block.chainid) return address(0);

        return _erc1155.balanceOf(msg.sender, tokenId) > 0 || _erc721Contracts[tokenId].ownerOf(tokenId) == msg.sender
            ? msg.sender
            : address(0);
    }

    function state() public view virtual override returns (uint256) {
        return _stateCounter;
    }

    function isValidSigner(address signer, bytes calldata) external view virtual override returns (bytes4) {
        if (owner() == signer) {
            return IERC6551Account.isValidSigner.selector;
        }

        return bytes4(0);
    }

    function isValidSignature(bytes32 hash, bytes memory signature) external view virtual override returns (bytes4) {
        bool isValid = ECDSA.recover(hash, signature) == owner();

        if (isValid) {
            return IERC1271.isValidSignature.selector;
        }

        return bytes4(0);
    }

    function execute(address to, uint256 value, bytes calldata data, uint8 operation)
        external
        payable
        virtual
        override
        returns (bytes memory result)
    {
        require(owner() == msg.sender, "Invalid signer");
        require(operation == 0, "Only call operations are supported");

        _stateCounter++;

        bool success;
        (success, result) = to.call{value: value}(data);

        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }

    function burn(uint256 tokenId) external {
        require(owner() == msg.sender, "Caller must own the pack");

        NFTInfo storage nftInfo = _getNFTInfo(tokenId);
        if (nftInfo.isERC721) {
            ERC721Burnable(address(_erc721Contracts[nftInfo.nftId])).burn(nftInfo.nftId);
        } else {
            _erc1155.safeTransferFrom(msg.sender, address(0), nftInfo.nftId, 1, "");
        }

        uint256 burnedNFTCount = getBurnedNFTCount(address(this));
        uint256 totalRarity = 0;
        for (uint256 i = 0; i < _nfts.length; i++) {
            uint256 adjustedRarity =
                _nfts[i].rarityBase + (_nfts[i].burned * rarityIncreaseFactor) + (burnedNFTCount * rarityIncreaseFactor);
            totalRarity += adjustedRarity;
        }
        uint256 randomNumber = _getRandomNumber(totalRarity);

        uint256 cumulativeRarity = 0;
        for (uint256 i = 0; i < _nfts.length; i++) {
            uint256 adjustedRarity =
                _nfts[i].rarityBase + (_nfts[i].burned * rarityIncreaseFactor) + (burnedNFTCount * rarityIncreaseFactor);
            if (randomNumber < cumulativeRarity + adjustedRarity) {
                // ... (existing code)
                break;
            }
            cumulativeRarity += adjustedRarity;
        }
    }

    function _getNFTInfo(uint256 tokenId) internal view returns (NFTInfo storage) {
        for (uint256 i = 0; i < _nfts.length; i++) {
            if (_nfts[i].nftId == tokenId) {
                return _nfts[i];
            }
        }
        revert("Invalid token ID");
    }

    function _getRandomNumber(uint256 maxNumber) internal view returns (uint256) {
        return uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao, msg.sender))) % maxNumber;
    }

    function getBurnedCounts() external view returns (uint256[] memory) {
        uint256[] memory burnedCounts = new uint256[](_nfts.length);
        for (uint256 i = 0; i < _nfts.length; i++) {
            burnedCounts[i] = _nfts[i].burned;
        }
        return burnedCounts;
    }

    function updateRaritySettings(uint256 newRarityIncreaseFactor) external onlyOwner {
        rarityIncreaseFactor = newRarityIncreaseFactor;
    }

    function addNFTToPack(uint256 nftId, uint256 rarityBase, bool isERC721, address erc721Contract)
        external
        onlyOwner
    {
        _nfts.push(NFTInfo(nftId, rarityBase, 0, isERC721));
        if (isERC721) {
            _erc721Contracts[nftId] = ERC721Burnable(erc721Contract);
        }
    }
}

contract NFTPack is ERC1155, Ownable {
    using ECDSA for bytes32;

    uint256 public packPrice;
    uint256 public maxSupply;

    uint256 private _tokenIdCounter;

    IERC6551Registry public immutable registry;
    NFTPackAccount public immutable accountImplementation;

    constructor(address registryAddress, uint256 _packPrice, uint256 _maxSupply, address _pluginAddress)
        Ownable()
        ERC1155("")
    {
        registry = IERC6551Registry(registryAddress);
        accountImplementation = new NFTPackAccount(address(this), _pluginAddress);
        packPrice = _packPrice;
        maxSupply = _maxSupply;
    }

    function mint(address to, uint256 tokenId, uint256 amount) external {
        require(msg.sender == owner() || msg.sender == address(registry), "Unauthorized minting");
        require(_tokenIdCounter < maxSupply, "All packs have been minted");

        _mint(to, tokenId, amount, "");
        _tokenIdCounter++;
        address account = registry.createAccount(
            address(accountImplementation), bytes32(tokenId), block.chainid, address(this), tokenId
        );

        _setApprovalForAll(account, address(accountImplementation), true);
    }

    function withdrawFunds() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }
}

contract NFTPackFactory is Ownable {
    struct Pack {
        address packAddress;
        uint256[] nftIds;
        uint256[] rarityBases;
    }

    enum RewardType {
        None,
        NFTPack,
        OtherReward
    }

    struct Pool {
        address token0;
        address token1;
        RewardType rewardType;
        address rewardNFTAddress;
        uint256 rewardNFTId;
        uint256[] rarityProbabilities;
        uint256 totalStaked;
    }

    mapping(uint256 => Pool) public pools;
    uint256 public nextPoolId;

    mapping(uint256 => Pack) public packs;
    uint256 public nextPackId;

    IERC6551Registry public immutable registry;

    constructor(address registryAddress) Ownable() {
        registry = IERC6551Registry(registryAddress);
        nextPackId = 1;
    }

    function createPack(
        address _token0,
        address _token1,
        RewardType _rewardType,
        address _rewardNFTAddress,
        uint256 _rewardNFTId,
        uint256[] memory _rarityProbabilities,
        uint256 _packPrice,
        uint256 _maxSupply,
        address _pluginAddress
    ) external onlyOwner returns (address) {
        require(_token0 != address(0) && _token1 != address(0), "Invalid token addresses");
        require(_token0 != _token1, "Tokens must be different");
        require(_rewardType != RewardType.None, "Invalid reward type");
        require(_rewardNFTAddress != address(0), "Invalid reward NFT address");
        NFTPackAccount packAccount = new NFTPackAccount(address(this), _pluginAddress);
        if (_rewardType == RewardType.NFTPack) {
            require(_rarityProbabilities.length > 0, "Rarity probabilities cannot be empty");
            uint256 totalProbability;
            for (uint256 i = 0; i < _rarityProbabilities.length; i++) {
                totalProbability += _rarityProbabilities[i];
            }
            require(totalProbability == 100, "Total probability must be 100");
        } else {
            _rarityProbabilities = new uint256[](0);
        }

        NFTPack packContract = new NFTPack(address(registry), _packPrice, _maxSupply, _pluginAddress); //currently needs 4 because of adding initial owner to the constructor, but probably should be registry address

        Pool memory newPool = Pool({
            token0: _token0,
            token1: _token1,
            rewardType: _rewardType,
            rewardNFTAddress: address(packContract),
            rewardNFTId: _rewardNFTId,
            rarityProbabilities: _rarityProbabilities,
            totalStaked: 0
        });

        uint256 poolId = nextPoolId;
        pools[poolId] = newPool;
        nextPoolId++;

        return address(packContract);
    }

    function mint(uint256 packId) external payable {
        Pack storage pack = packs[packId];
        require(pack.packAddress != address(0), "Invalid pack ID");

        NFTPackAccount packAccount = NFTPackAccount(pack.packAddress);
        uint256 tokenId = IERC1155(address(this)).balanceOf(address(packAccount), packId);

        address account =
            registry.createAccount(address(packAccount), bytes32(tokenId), block.chainid, address(packAccount), tokenId);

        IERC1155(address(this)).safeTransferFrom(address(this), account, packId, 1, "");
    }
}
