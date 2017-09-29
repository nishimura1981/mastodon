class SuggestedAccountQuery
  attr_reader :excluded_ids, :seed, :limit, :page_number

  def initialize
    @excluded_ids = []
    @seed = Random.new_seed
    @limit = 20
    @page_number = 0
  end

  def exclude_ids(ids)
    spawn(excluded_ids: (excluded_ids + ids).uniq)
  end

  def shuffle(seed)
    spawn(seed: seed)
  end

  def per(limit)
    spawn(limit: limit.to_i)
  end

  def page(page_number)
    spawn(page_number: page_number.to_i)
  end

  concerning :TradicAccountQuery do
    included do
      attr_reader :account, :with_tradic_limit
    end

    def with_tradic(account, limit: 4)
      spawn(account: account, with_tradic_limit: limit.to_i)
    end

    private

    def triadic_account_ids
      return [] unless enable_tradic_account_query?

      offset = with_tradic_limit * page_number
      accounts = Account.triadic_closures(account, offset: offset, limit: with_tradic_limit, exclude_ids: excluded_ids)
      accounts.map(&:id)
    end

    def enable_tradic_account_query?
      with_tradic_limit.to_i.positive? && account
    end
  end

  concerning :PixivFollowQuery do
    included do
      attr_reader :oauth_authentication, :with_pixiv_follows_limit
    end

    def with_pixiv_follows(oauth_authentication, limit: 4)
      spawn(oauth_authentication: oauth_authentication, with_pixiv_follows_limit: limit.to_i)
    end

    private

    def pixiv_following_account_ids
      return [] unless enable_pixiv_follows_query?

      uids = oauth_authentication.pixiv_follows.pluck(:target_pixiv_uid)

      # メディアを投稿しているユーザーだけを取り出すため、media_attachmentsとjoinする
      account_ids = default_scoped.joins(:media_attachments)
                                  .joins(:user)
                                  .where.not(id: excluded_ids)
                                  .joins(:oauth_authentications)
                                  .where(oauth_authentications: { provider: 'pixiv', uid: uids })
                                  .distinct
                                  .pluck(:id)

      Account.filter_by_time(account_ids)
    end

    def enable_pixiv_follows_query?
      with_pixiv_follows_limit.to_i.positive? && oauth_authentication
    end
  end

  concerning :PopularAccountQuery do
    private

    def popular_account_ids
      ids = all_popular_account_ids - excluded_ids

      active_ids = Account.filter_by_time(ids)

      #アクティブなアカウントを先に表示する
      shuffle_ids(active_ids) + shuffle_ids(ids - active_ids)
    end

    # TODO: 自動的に検出するようにする
    # - localのみ
    # - R18を除く
    # - ファボ・フォロワー数・画像投稿経験の高いユーザーを上位から抜き出す
    # - フォロー数がフォロワー数より多いユーザーを閾値を設けて除外する
    # - 絵をよく投稿しているユーザーを優先する
    # - 社員は抜く(目視チェック)
    def all_popular_account_ids
      key = 'SuggestedAccountQuery:suggested_account_ids'
      Redis.current.zrange(key, 0, -1).map(&:to_i)
    end
  end

  def all
    ids = []
    ids += pickup(pixiv_following_account_ids, limit: with_pixiv_follows_limit)
    ids += (triadic_account_ids - ids)
    ids += pickup(popular_account_ids - ids, limit: limit - ids.length) # limitに達する数までidを取得する

    # sort_byにより、取得したAccountがidsの順番通りになるよう再度並び替える
    default_scoped.where(id: ids)
                  .preload(:media_attachments, :oauth_authentications)
                  .limit(limit)
                  .sort_by { |account| ids.index(account.id) }
  end

  private

  def pickup(ids, limit: 0)
    offset = limit * page_number
    ids.slice(offset, limit) || []
  end

  def shuffle_ids(ids)
    ids.shuffle(random: Random.new(seed))
  end

  def spawn(variables)
    dup.tap do |instance|
      variables.each { |key, value| instance.instance_variable_set("@#{key}", value) }
    end
  end

  def default_scoped
    Account.local.where(suspended: false, silenced: false)
  end
end
