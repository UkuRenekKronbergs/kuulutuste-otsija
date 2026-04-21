# Iga saidi scraper tagastab listings massiivi järgmise kujuga:
# @{ id; title; price; url; site; location; date; keyword }

. (Join-Path $PSScriptRoot 'common.ps1')

function Get-SoovListings {
    param([string]$Keyword, [object]$Config)
    $encoded = [uri]::EscapeDataString($Keyword)
    $url = "https://soov.ee/keyword-$encoded/order-price/order_way-asc/listings.html"
    $resp = Invoke-CurlFetch -Url $url -UserAgent $Config.user_agent
    if (-not $resp -or $resp.StatusCode -ne 200) {
        Write-Warning "soov.ee: $url - status $($resp.StatusCode)"
        return @()
    }
    $html = $resp.Body
    $results = @()
    # Iga kuulutus on <div class="item-list category-view category-id-XXX" id="LXXXXXXXXX"> ... </div>
    $pattern = '(?s)<div class="item-list category-view[^"]*"\s+id="L(\d+)">(.*?)<!--/\.item-list-->'
    $matches = [regex]::Matches($html, $pattern)
    foreach ($m in $matches) {
        $id = $m.Groups[1].Value
        $block = $m.Groups[2].Value

        $titleMatch = [regex]::Match($block, '(?s)<h4 class="add-title">(.*?)</h4>')
        $urlMatch = [regex]::Match($block, '<a\s+href="(https://soov\.ee/[^"]*/details\.html)"')
        $priceMatch = [regex]::Match($block, '<h4 class="item-price[^"]*">([^<]+)</h4>')
        $locMatch = [regex]::Match($block, '(?s)<span class="item-location">.*?<i[^>]*></i>\s*(?:&nbsp;)?\s*([^<]+?)\s*</span>')
        $dateMatch = [regex]::Match($block, '<span class="date" title="([^"]+)">')

        if (-not $titleMatch.Success -or -not $urlMatch.Success -or -not $priceMatch.Success) { continue }

        $title = Remove-HtmlTags ($titleMatch.Groups[1].Value -replace '<span class="thin">[^<]*</span>', '')
        $price = ConvertFrom-PriceString $priceMatch.Groups[1].Value
        if ($null -eq $price) { continue }
        if (-not (Test-MatchesKeyword -Title $title -Keyword $Keyword)) { continue }

        $results += [pscustomobject]@{
            id       = "soov:$id"
            title    = $title
            price    = $price
            url      = $urlMatch.Groups[1].Value
            site     = 'soov.ee'
            location = if ($locMatch.Success) { (Remove-HtmlTags $locMatch.Groups[1].Value) } else { '' }
            date     = if ($dateMatch.Success) { $dateMatch.Groups[1].Value } else { '' }
            keyword  = $Keyword
        }
    }
    $results
}

function Get-OstaListings {
    param([string]$Keyword, [object]$Config)
    $encoded = [uri]::EscapeDataString($Keyword)
    # osta.ee otsing: /?fuseaction=search.search&q[q]=KEYWORD&q[cat]=1000&q[show_items]=1
    $url = "https://www.osta.ee/?fuseaction=search.search&q%5Bq%5D=$encoded&q%5Bcat%5D=1000&q%5Bshow_items%5D=1"
    $profile = $null
    if ($Config.edge_profile_dir) { $profile = $Config.edge_profile_dir }
    $resp = Invoke-EdgeFetch -Url $url -WaitMs $Config.edge_wait_ms -UserAgent $Config.user_agent -ProfileDir $profile
    if (-not $resp -or -not $resp.Body) {
        Write-Warning "osta.ee: ei saanud vastust"
        return @()
    }
    $html = $resp.Body
    if ($html -match 'Just a moment' -or $html -match 'Vabandame, meie s.steem') {
        Write-Warning "osta.ee: anti-bot blokeeris (suurenda edge_wait_ms)"
        return @()
    }
    $results = @()
    # Iga kuulutus: <figure ... data-analytics-ecommerce-target="item" data-title="..." data-price="..." ...>
    # Algus-tag sisaldab kogu vajaliku metainfo (title, price), URL on järgmisel real <a href="/...-ID.html">
    $pattern = '<figure[^>]+data-analytics-ecommerce-target="item"[^>]*>'
    $figs = [regex]::Matches($html, $pattern)
    foreach ($f in $figs) {
        # Lõika välja block: algus-tagist järgmise 2KB
        $endIdx = [math]::Min($f.Index + 3000, $html.Length)
        $block = $html.Substring($f.Index, $endIdx - $f.Index)
        $titleMatch  = [regex]::Match($f.Value, 'data-title="([^"]*)"')
        $priceMatch  = [regex]::Match($f.Value, 'data-price="([^"]*)"')
        $linkMatch   = [regex]::Match($block, 'href="(/[^"]*-(\d{7,})\.html)"')
        if (-not $titleMatch.Success -or -not $priceMatch.Success -or -not $linkMatch.Success) { continue }

        $title = ConvertFrom-HtmlEntities $titleMatch.Groups[1].Value
        if (-not (Test-MatchesKeyword -Title $title -Keyword $Keyword)) { continue }

        $price = ConvertFrom-PriceString $priceMatch.Groups[1].Value
        if ($null -eq $price) { continue }

        $id = $linkMatch.Groups[2].Value
        $href = "https://www.osta.ee$($linkMatch.Groups[1].Value)"

        $dateMatch = [regex]::Match($block, '(?s)offer-thumb__metadata--item[^>]*>\s*<span>\s*([^<]+?)\s*</span>')

        $results += [pscustomobject]@{
            id       = "osta:$id"
            title    = $title
            price    = $price
            url      = $href
            site     = 'osta.ee'
            location = ''
            date     = if ($dateMatch.Success) { ($dateMatch.Groups[1].Value.Trim()) } else { '' }
            keyword  = $Keyword
        }
    }
    $results
}

function Get-OkidokiListings {
    param([string]$Keyword, [object]$Config)
    $encoded = [uri]::EscapeDataString($Keyword)
    $url = "https://www.okidoki.ee/buy/all/?query=$encoded&p_min=&p_max=&sort=price_asc"
    $profile = $null
    if ($Config.edge_profile_dir) { $profile = $Config.edge_profile_dir }
    $resp = Invoke-EdgeFetch -Url $url -WaitMs $Config.edge_wait_ms -UserAgent $Config.user_agent -ProfileDir $profile
    if (-not $resp -or -not $resp.Body) {
        Write-Warning "okidoki.ee: ei saanud vastust"
        return @()
    }
    $html = $resp.Body
    if ($html -match 'Just a moment|Cloudflare') {
        Write-Warning "okidoki.ee: Cloudflare blokeeris"
        return @()
    }
    $results = @()
    # okidoki.ee kuulutused: <a href="/buy/.../123456/">
    $pattern = '(?s)<a\s+[^>]*href="(/buy/[^"]+/(\d+)/?)"[^>]*class="[^"]*offer[^"]*"[^>]*>(.*?)</a>'
    $matches = [regex]::Matches($html, $pattern)
    if ($matches.Count -eq 0) {
        # Tagavara muster - mis iganes /buy/.../DIGITS/ lingid
        $pattern2 = '(?s)<a[^>]+href="(/buy/[^"]+/(\d+)/?)"[^>]*>(.*?)</a>'
        $matches = [regex]::Matches($html, $pattern2)
    }
    $seenIds = @{}
    foreach ($m in $matches) {
        $id = $m.Groups[2].Value
        if ($seenIds.ContainsKey($id)) { continue }
        $seenIds[$id] = $true
        $href = "https://www.okidoki.ee$($m.Groups[1].Value)"
        $inner = $m.Groups[3].Value
        $title = Remove-HtmlTags $inner
        if (-not $title -or $title.Length -lt 3) { continue }
        if (-not (Test-MatchesKeyword -Title $title -Keyword $Keyword)) { continue }

        # Hind läheduses
        $startIdx = [math]::Max(0, $m.Index - 300)
        $context = $html.Substring($startIdx, [math]::Min(1500, $html.Length - $startIdx))
        $priceMatch = [regex]::Match($context, '(\d{1,3}(?:[\s\u00A0]\d{3})*(?:[,\.]\d+)?)\s*€')
        if (-not $priceMatch.Success) { continue }
        $price = ConvertFrom-PriceString $priceMatch.Groups[1].Value
        if ($null -eq $price) { continue }

        $results += [pscustomobject]@{
            id       = "okidoki:$id"
            title    = $title
            price    = $price
            url      = $href
            site     = 'okidoki.ee'
            location = ''
            date     = ''
            keyword  = $Keyword
        }
    }
    $results
}

function Get-KuldneborsListings {
    param([string]$Keyword, [object]$Config)
    $encoded = [uri]::EscapeDataString($Keyword)
    $url = "https://www.kuldnebors.ee/search/search.mec?search_O_string=$encoded&pob_action=search"
    $profile = $null
    if ($Config.edge_profile_dir) { $profile = $Config.edge_profile_dir }
    $resp = Invoke-EdgeFetch -Url $url -WaitMs $Config.edge_wait_ms -UserAgent $Config.user_agent -ProfileDir $profile
    if (-not $resp -or -not $resp.Body) {
        Write-Warning "kuldnebors.ee: ei saanud vastust"
        return @()
    }
    $html = $resp.Body
    if ($html -match 'Vabandame, meie s.steem') {
        Write-Warning "kuldnebors.ee: anti-bot blokeeris"
        return @()
    }
    $results = @()
    # Iga kuulutus: <div class="row kb-object" data-post-row="ID">...</div>
    $pattern = '(?s)<div class="row kb-object" data-post-row="(\d+)">(.*?)(?=<div class="row kb-object"|<div class="kb-pagination|<footer|</body>)'
    $matches = [regex]::Matches($html, $pattern)
    foreach ($m in $matches) {
        $id = $m.Groups[1].Value
        $block = $m.Groups[2].Value

        # Välista "ostan" kuulutused (pob_deal_type=O)
        if ($block -match 'pob_deal_type=O[^a-zA-Z]') { continue }

        $titleMatch = [regex]::Match($block, '(?s)<h4 class="kb-object__heading[^"]*"><a[^>]+href="([^"]+)"[^>]*>([^<]+)</a>')
        if (-not $titleMatch.Success) { continue }
        $relUrl = ConvertFrom-HtmlEntities $titleMatch.Groups[1].Value
        $title = ConvertFrom-HtmlEntities $titleMatch.Groups[2].Value
        if (-not (Test-MatchesKeyword -Title $title -Keyword $Keyword)) { continue }

        # Hind: viimane <span class="fgN">X €</span> on praegune hind (eelnev võib olla läbikriipsutatud)
        $priceMatches = [regex]::Matches($block, '<span class="fg\d+">([^<]+?)</span>')
        $priceText = $null
        foreach ($pm in $priceMatches) { $priceText = $pm.Groups[1].Value }
        if (-not $priceText) {
            # Tagavara: otse <span class="kb-object__price">
            $pm2 = [regex]::Match($block, '(?s)<span class="kb-object__price">.*?(\d[\d\s.,]*)\s*€')
            if ($pm2.Success) { $priceText = $pm2.Groups[1].Value }
        }
        if (-not $priceText) { continue }
        $price = ConvertFrom-PriceString $priceText
        if ($null -eq $price) { continue }

        $locMatch = [regex]::Match($block, '(?s)<div class="kb-object__location[^"]*">.*?</span>([^<]+)</div>')
        $dateMatch = [regex]::Match($block, '<div class="kb-object__date">\s*sisestatud\s+([\d.]+)\s*</div>')

        $href = if ($relUrl -match '^https?://') { $relUrl } else { "https://www.kuldnebors.ee$relUrl" }

        $results += [pscustomobject]@{
            id       = "kuldnebors:$id"
            title    = $title
            price    = $price
            url      = $href
            site     = 'kuldnebors.ee'
            location = if ($locMatch.Success) { (Remove-HtmlTags $locMatch.Groups[1].Value) } else { '' }
            date     = if ($dateMatch.Success) { $dateMatch.Groups[1].Value } else { '' }
            keyword  = $Keyword
        }
    }
    $results
}

function Get-YagaListings {
    param([string]$Keyword, [object]$Config)
    # Yaga.ee on React/Next.js SPA ja näitab tulemustes ainult hinda + brändi, mitte toote pealkirja.
    # Pealkirja saamiseks tuleks iga toote lehe eraldi pärida, mis oleks väga aeglane.
    # Selle tõttu kasutame brändi ja URL-i keyword-matchinguks (nt otsides "Apple" leiame Apple'i tooteid).
    # Yaga on peamiselt moemaja - elektroonikat sealt harva leiab.
    $encoded = [uri]::EscapeDataString($Keyword)
    $url = "https://www.yaga.ee/search?q=$encoded"
    $profile = $null
    if ($Config.edge_profile_dir) { $profile = $Config.edge_profile_dir }
    $waitMs = [math]::Max($Config.edge_wait_ms, 25000)  # Yaga vajab pikemat aega kliendipoolsete päringute jaoks
    $resp = Invoke-EdgeFetch -Url $url -WaitMs $waitMs -UserAgent $Config.user_agent -ProfileDir $profile
    if (-not $resp -or -not $resp.Body) {
        Write-Warning "yaga.ee: ei saanud vastust"
        return @()
    }
    $html = $resp.Body
    $results = @()
    # Struktuur: <a class="no-style" href="/SHOP/toode/ID?rank=N">...<h5 class="price">33&nbsp;€</h5>...<div class="brand-container"><h5 class="details">BRAND</h5></div></a>
    $pattern = '(?s)<a class="no-style" href="(/[^/]+/toode/([a-z0-9]+)\?rank=\d+)"[^>]*>(.*?)</a>'
    $matches = [regex]::Matches($html, $pattern)
    foreach ($m in $matches) {
        $id = $m.Groups[2].Value
        $href = "https://www.yaga.ee$($m.Groups[1].Value)"
        $block = $m.Groups[3].Value

        $priceMatch = [regex]::Match($block, '<h5 class="price">([^<]+)</h5>')
        if (-not $priceMatch.Success) { continue }
        $price = ConvertFrom-PriceString $priceMatch.Groups[1].Value
        if ($null -eq $price) { continue }

        $brandMatch = [regex]::Match($block, '(?s)<div class="brand-container">.*?<h5 class="details">([^<]+)</h5>')
        $brand = if ($brandMatch.Success) { ConvertFrom-HtmlEntities $brandMatch.Groups[1].Value } else { '' }

        # Yaga'l pole pealkirja - kasutame brändi + shop-slug-i kombineeritult
        $shopMatch = [regex]::Match($m.Groups[1].Value, '/([^/]+)/toode/')
        $shop = if ($shopMatch.Success) { $shopMatch.Groups[1].Value } else { '' }
        $pseudoTitle = (@($brand, $shop) | Where-Object { $_ } | ForEach-Object { $_ }) -join ' '
        if (-not $pseudoTitle) { $pseudoTitle = $id }

        # Kuna puudub täiskategooria pealkiri, teeme substring-matchingu brändi/shop suhtes
        if (-not (Test-MatchesKeyword -Title $pseudoTitle -Keyword $Keyword)) { continue }

        $results += [pscustomobject]@{
            id       = "yaga:$id"
            title    = $pseudoTitle
            price    = $price
            url      = $href
            site     = 'yaga.ee'
            location = ''
            date     = ''
            keyword  = $Keyword
        }
    }
    $results
}

function Get-AllListings {
    param([string]$Keyword, [object]$Config)
    $all = @()
    if ($Config.sites.soov)       { try { $all += Get-SoovListings       -Keyword $Keyword -Config $Config } catch { Write-Warning "soov: $_" } }
    if ($Config.sites.osta)       { try { $all += Get-OstaListings       -Keyword $Keyword -Config $Config } catch { Write-Warning "osta: $_" } }
    if ($Config.sites.okidoki)    { try { $all += Get-OkidokiListings    -Keyword $Keyword -Config $Config } catch { Write-Warning "okidoki: $_" } }
    if ($Config.sites.kuldnebors) { try { $all += Get-KuldneborsListings -Keyword $Keyword -Config $Config } catch { Write-Warning "kuldnebors: $_" } }
    if ($Config.sites.yaga)       { try { $all += Get-YagaListings       -Keyword $Keyword -Config $Config } catch { Write-Warning "yaga: $_" } }
    $all
}
