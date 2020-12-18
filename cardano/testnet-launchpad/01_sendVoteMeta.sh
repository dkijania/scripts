#!/bin/bash

# Script is brought to you by ATADA_Stakepool, Telegram @atada_stakepool in
# cooperation with @TheRealAdamDean (BUFFY & SPIKE)

#load variables from common.sh
#       socket          Path to the node.socket (also exports socket to CARDANO_NODE_SOCKET_PATH)
#       genesisfile     Path to the genesis.json
#       magicparam      TestnetMagic parameter
#       cardanocli      Path to the cardano-cli executable
. "$(dirname "$0")"/00_common.sh

case $# in
  2 ) fromAddr="$1";
      metafile="$2.json";;
  * ) cat >&2 <<EOF
Usage:  $(basename $0) <From AddressName> <VoteFileName>.json
EOF
  exit 1;; esac

#This is a simplified Version of the sendLovelaces.sh script so, it will always be a SendALLLovelaces transaction + Metafile
toAddr=${fromAddr}
lovelacesToSend="ALL"

#Throw an error if the voting.json file does not exist
if [ ! -f "${metafile}" ]; then
  echo -e "The specified VoteFileName.json (${metafile} file does not exist. Please try again."
  exit 1
fi

function readMetaParam() {
  required="${3:-0}"
  key=$(jq 'keys[0]' $2)
  param=$(jq -r ".$key .$1" $2 2> /dev/null)
  if [[ $? -ne 0 ]]; then echo "ERROR - ${2} is not a valid JSON file" >&2; exit 1;
  elif [[ "${param}" == null && required -eq 1 ]]; then echo "ERROR - Parameter \"$1\" in ${2} does not exist" >&2; exit 1;
  elif [[ "${param}" == "" && !required -eq 1 ]]; then echo "ERROR - Parameter \"$1\" in ${2} is empty" >&2; exit 1;
  fi
  echo "${param}"
}

objectType=$(readMetaParam "ObjectType" "${metafile}" 1); if [[ ! $? == 0 ]]; then exit 1; fi
objectVersion=$(readMetaParam "ObjectVersion" "${metafile}"); if [[ ! $? == 0 ]]; then exit 1; fi

if [[ $objectType == 'VoteBallot' ]]; then
  # Check VoteBallot required fields
  networkId=$(readMetaParam "NetworkId" "${metafile}" 1); if [[ ! $? == 0 ]]; then exit 1; fi
  proposalId=$(readMetaParam "ProposalId" "${metafile}" 1); if [[ ! $? == 0 ]]; then exit 1; fi
  voterId=$(readMetaParam "VoterId" "${metafile}" 1); if [[ ! $? == 0 ]]; then exit 1; fi
  yesnovote=$(readMetaParam "Vote" "${metafile}"); if [[ ! $? == 0 ]]; then exit 1; fi
  choicevote=$(readMetaParam "Choices" "${metafile}"); if [[ ! $? == 0 ]]; then exit 1; fi
  if [[ $yesnovote == null && $choicevote == null ]]; then
    echo "ERROR - No voting preferences found in ballot.";
    exit 1;
  fi
else
    echo "ERROR - JSON is not of type VoteBallot.";
    exit 1;
fi

sendFromAddr=$(cat ${fromAddr}.addr)
sendToAddr=$(cat ${toAddr}.addr)
check_address "${sendFromAddr}"
check_address "${sendToAddr}"

rxcnt="1"

echo
echo -e "\e[0mUsing lovelaces from Address\e[32m ${fromAddr}.addr\e[0m to send the metafile\e[32m ${metafile}\e[0m:"
echo

#get live values
currentTip=$(get_currentTip)
ttl=$(get_currentTTL)
currentEPOCH=$(get_currentEpoch)

echo -e "\e[0mCurrent Slot-Height:\e[32m ${currentTip} \e[0m(setting TTL[invalid_hereafter] to ${ttl})"
echo
echo -e "\e[0mSource/Destination Address ${fromAddr}.addr:\e[32m ${sendFromAddr} \e[90m"
echo -e "\e[0mAttached Metafile:\e[32m ${metafile} \e[90m"
echo

#-------------------------------------
#
# Checking UTXO Data of the source address and gathering data about total lovelaces and total assets
#
	utxoJSON=$(${cardanocli} ${subCommand} query utxo --address ${sendFromAddr} --cardano-mode ${magicparam} ${nodeEraParam} --out-file /dev/stdout); checkError "$?";
	txcnt=$(jq length <<< ${utxoJSON}) #Get number of UTXO entries (Hash#Idx), this is also the number of --tx-in for the transaction
	if [[ ${txcnt} == 0 ]]; then echo -e "\e[35mNo funds on the Source Address!\e[0m\n"; exit; else echo -e "\e[32m${txcnt} UTXOs\e[0m found on the Source Address!\n"; fi

        #Convert UTXO into mary style if UTXO is shelley/allegra style
        if [[ ! "$(jq -r '[.[]][0].amount | type' <<< ${utxoJSON})" == "array" ]]; then utxoJSON=$(convert_UTXO "${utxoJSON}"); fi

	#Calculating the total amount of lovelaces in all utxos on this address
        totalLovelaces=$(jq '[.[].amount[0]] | add' <<< ${utxoJSON})

        totalAssetsJSON="{}"; 	#Building a total JSON with the different assetstypes "policyIdHash.name", amount and name
        totalPolicyIDsJSON="{}"; #Holds the different PolicyIDs as values "policyIDHash", length is the amount of different policyIDs

	assetsOutString="";	#This will hold the String to append on the --tx-out if assets present or it will be empty

        #For each utxo entry, check the utxo#index and check if there are also any assets in that utxo#index
        #LEVEL 1 - different UTXOs
        for (( tmpCnt=0; tmpCnt<${txcnt}; tmpCnt++ ))
        do
        utxoHashIndex=$(jq -r "keys[${tmpCnt}]" <<< ${utxoJSON})
        utxoAmount=$(jq -r ".\"${utxoHashIndex}\".amount[0]" <<< ${utxoJSON})   #Lovelaces
        echo -e "Hash#Index: ${utxoHashIndex}\tAmount: ${utxoAmount}"
        assetsJSON=$(jq -r ".\"${utxoHashIndex}\".amount[1]" <<< ${utxoJSON})
        assetsEntryCnt=$(jq length <<< ${assetsJSON})
        if [[ ${assetsEntryCnt} -gt 0 ]]; then
                        #LEVEL 2 - different policyID/assetHASH
                        for (( tmpCnt2=0; tmpCnt2<${assetsEntryCnt}; tmpCnt2++ ))
                        do
                        assetHash=$(jq -r ".[${tmpCnt2}][0]" <<< ${assetsJSON})  #assetHash = policyID
                        assetsNameCnt=$(jq ".[${tmpCnt2}][1] | length" <<< ${assetsJSON})
                        totalPolicyIDsJSON=$( jq ". += {\"${assetHash}\": 1}" <<< ${totalPolicyIDsJSON})

                                #LEVEL 3 - different names under the same policyID
                                for (( tmpCnt3=0; tmpCnt3<${assetsNameCnt}; tmpCnt3++ ))
                                do
                                assetName=$(jq -r ".[${tmpCnt2}][1][${tmpCnt3}][0]" <<< ${assetsJSON})
                                assetAmount=$(jq -r ".[${tmpCnt2}][1][${tmpCnt3}][1]" <<< ${assetsJSON})
                                oldValue=$(jq -r ".\"${assetHash}.${assetName}\".amount" <<< ${totalAssetsJSON})
                                newValue=$((${oldValue}+${assetAmount}))
                                totalAssetsJSON=$( jq ". += {\"${assetHash}.${assetName}\":{amount: ${newValue}, name: \"${assetName}\"}}" <<< ${totalAssetsJSON})
                                echo -e "\e[90m            PolID: ${assetHash}\tAmount: ${assetAmount} ${assetName}\e[0m"
                                done
                         done
        fi
        txInString="${txInString} --tx-in ${utxoHashIndex}"
        done
        echo -e "\e[0m-----------------------------------------------------------------------------------------------------"
        totalInADA=$(bc <<< "scale=6; ${totalLovelaces} / 1000000")
        echo -e "Total ADA on the Address:\e[32m  ${totalInADA} ADA / ${totalLovelaces} lovelaces \e[0m\n"
        totalPolicyIDsCnt=$(jq length <<< ${totalPolicyIDsJSON});
        totalAssetsCnt=$(jq length <<< ${totalAssetsJSON})
        if [[ ${totalAssetsCnt} -gt 0 ]]; then
                        echo -e "\e[32m${totalAssetsCnt} Asset-Type(s) / ${totalPolicyIDsCnt} different PolicyIDs\e[0m found on the Address!\n"
                        printf "\e[0m%-70s %16s %s\n" "PolicyID.Name:" "Total-Amount:" "Name:"
                        for (( tmpCnt=0; tmpCnt<${totalAssetsCnt}; tmpCnt++ ))
                        do
                        assetHashName=$(jq -r "keys[${tmpCnt}]" <<< ${totalAssetsJSON})
                        assetAmount=$(jq -r ".\"${assetHashName}\".amount" <<< ${totalAssetsJSON})
                        assetName=$(jq -r ".\"${assetHashName}\".name" <<< ${totalAssetsJSON})
                        printf "\e[90m%-70s \e[32m%16s %s\e[0m\n" "${assetHashName}" "${assetAmount}" "${assetName}"
                        if [[ ${assetAmount} -gt 0 ]]; then assetsOutString+="+${assetAmount} ${assetHashName}"; fi #only include in the sendout if more than zero
                        done
        fi
echo

#Getting protocol parameters from the chain
protocolParametersJSON=$(${cardanocli} ${subCommand} query protocol-parameters --cardano-mode ${magicparam} ${nodeEraParam})
checkError "$?"
minOutUTXO=$(get_minOutUTXO "${protocolParametersJSON}" "${totalAssetsCnt}" "${totalPolicyIDsCnt}")

#-------------------------------------


#Generate Dummy-TxBody file for fee calculation
txBodyFile="${tempDir}/dummy.txbody"
rm ${txBodyFile} 2> /dev/null
${cardanocli} ${subCommand} transaction build-raw ${nodeEraParam} ${txInString} --tx-out "${dummyShelleyAddr}+0${assetsOutString}" --invalid-hereafter ${ttl} --fee 0 --metadata-json-file ${metafile} --out-file ${txBodyFile}
checkError "$?"
fee=$(${cardanocli} ${subCommand} transaction calculate-min-fee --tx-body-file ${txBodyFile} --protocol-params-file <(echo ${protocolParametersJSON}) --tx-in-count ${txcnt} --tx-out-count ${rxcnt} ${magicparam} --witness-count 1 --byron-witness-count 0 | awk '{ print $1 }')
checkError "$?"
echo -e "\e[0mMinimum Transaction Fee for ${txcnt}x TxIn & ${rxcnt}x TxOut: \e[32m ${fee} lovelaces \e[90m"

lovelacesToSend=$(( ${totalLovelaces} - ${fee} ))

echo -e "\e[0mLovelaces that will be returned to payment Address (UTXO-Sum minus fees): \e[32m ${lovelacesToSend} lovelaces \e[90m (min. required ${minOutUTXO} lovelaces)"
echo

#Checking about minimum funds in the UTX0
if [[ ${lovelacesToSend} -lt ${minOutUTXO} ]]; then echo -e "\e[35mNot enough funds on the source Addr! Minimum UTXO value is ${minOutUTXO} lovelaces.\e[0m"; exit; fi


txBodyFile="${tempDir}/$(basename ${fromAddr}).txbody"
txFile="${tempDir}/$(basename ${fromAddr}).tx"

echo
echo -e "\e[0mBuilding the unsigned transaction body: \e[32m ${txBodyFile} \e[90m"
echo

#Building unsigned transaction body
rm ${txBodyFile} 2> /dev/null
${cardanocli} ${subCommand} transaction build-raw ${nodeEraParam} ${txInString} --tx-out "${sendToAddr}+${lovelacesToSend}${assetsOutString}" --invalid-hereafter ${ttl} --fee ${fee} --metadata-json-file ${metafile} --out-file ${txBodyFile}
checkError "$?"

cat ${txBodyFile}
echo

echo -e "\e[0mSign the unsigned transaction body with the \e[32m${fromAddr}.skey\e[0m: \e[32m ${txFile} \e[90m"
echo

#Sign the unsigned transaction body with the SecureKey
rm ${txFile} 2> /dev/null
${cardanocli} ${subCommand} transaction sign --tx-body-file ${txBodyFile} --signing-key-file ${fromAddr}.skey ${magicparam} --out-file ${txFile} 
checkError "$?"

cat ${txFile}
echo

if ask "\e[33mDoes this look good for you, continue ?" N; then
	echo
	echo -ne "\e[0mSubmitting the transaction via the node..."
	${cardanocli} ${subCommand} transaction submit --tx-file ${txFile} --cardano-mode ${magicparam}
	checkError "$?"
	echo -e "\e[32mDONE\n"
fi


echo -e "\e[0m\n"
