module Today
  def self.said
    "Today is #{Date.current.strftime('%A, %B %-d, %Y')}. Anything dated before it is in the past, " \
      "and anything dated after it is still to come."
  end
end
