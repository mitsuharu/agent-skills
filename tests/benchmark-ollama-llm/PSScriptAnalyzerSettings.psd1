@{
    ExcludeRules = @(
        # コンソール表示用に Write-Host を使う
        'PSAvoidUsingWriteHost',
        # スクリプトパラメーターを関数内で使う場合の誤検知
        'PSReviewUnusedParameter'
    )
}
