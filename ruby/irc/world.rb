# Created by Satoshi Nakagawa.
# You can redistribute it and/or modify it under the Ruby's license or the GPL2.

require 'date'

class IRCWorld < OSX::NSObject
  include OSX
  attr_accessor :member_list, :dcc
  attr_writer :tree, :log_base, :console_base, :text, :window, :pref
  attr_accessor :menu_controller
  attr_accessor :tree_default_menu, :server_menu, :channel_menu, :tree_menu, :log_menu, :console_menu, :url_menu, :addr_menu, :member_menu
  attr_reader :units, :selected, :console, :config
  
  AUTO_CONNECT_DELAY = 1
  
  def initialize
    @units = []
    @unit_id = 0
    @channel_id = 0
    @growl = GrowlController.new
    @growl.owner = self
    @today = Date.today
  end
  
  def setup(seed)
    @logtheme = LogTheme.new(@pref.theme.log_theme)
    @console = create_log(nil, true)
    @console_base.setContentView(@console.view)
    @dummylog = create_log(nil, true)
    @log_base.setContentView(@dummylog.view)
    
    @config = seed.dup
    @config.units.each {|u| create_unit(u) } if @config.units
    @config.units = nil

    register_growl
  end
  
  def save
    @pref.save_world(to_dic)
  end
  
  def setup_tree
    @tree.setTarget(self)
    @tree.setDoubleAction('outlineView_doubleClicked:')
    
    unit = @units.find {|u| u.config.auto_connect }
    if unit
      expand_unit(unit)
      unless unit.channels.empty?
        @tree.select(@tree.rowForItem(unit)+1)
      else
        @tree.select(@tree.rowForItem(unit))
      end
    end
  end
  
  def terminate
    @units.each {|u| u.terminate }
  end
  
  def update_order(w)
    ary = []
    w.units.each do |i|
      u = find_unit_by_id(i.id)
      if u
        u.update_order(i)
        ary << u
        @units.delete(u)
      end
    end
    ary += @units
    @units = ary
    reload_tree
    adjust_selection
    save
  end
  
  def update_autoop(w)
    @config.autoop = w.autoop
    w.units.each do |i|
      u = find_unit_by_id(i.id)
      u.update_autoop(i) if u
    end
    save
  end
  
  def store_tree
    w = @config.dup
    w.units = @units.map {|u| u.store_config }
    w
  end
  
  def auto_connect
    delay = 0
    @units.each do |u|
      if u.config.auto_connect
        u.auto_connect(delay)
        delay += AUTO_CONNECT_DELAY
      end
    end
  end
  
  def selunit
    return nil unless @selected
    @selected.unit? ? @selected : @selected.unit
  end
  
  def selchannel
    return nil unless @selected
    @selected.unit? ? nil : @selected
  end
  
  def sel
    [selunit, selchannel]
  end
  
  def to_dic
    h = @config.to_dic
    unless @units.empty?
      h[:units] = @units.map {|i| i.to_dic } 
    end
    h
  end
  
  def find_unit(name)
    @units.find {|u| u.name == name }
  end
  
  def find_unit_by_id(uid)
    @units.find {|u| u.id == uid }
  end
  
  def find_channel_by_id(uid, cid)
    unit = @units.find {|u| u.id == uid }
    return nil unless unit
    unit.channels.find {|c| c.id == cid }
  end
  
  def find_by_id(uid, cid)
    unit = find_unit_by_id(uid)
    return [] unless unit
    channel = unit.find_channel_by_id(cid)
    [unit, channel]
  end
  
  def create_unit(seed, reload=true)
    @unit_id += 1
    u = IRCUnit.alloc.init
    u.id = @unit_id
    u.world = self
    u.pref = @pref
    u.log = create_log(u)
    u.setup(seed)
    seed.channels.each {|c| create_channel(u, c) } if seed.channels
    @units << u
    reload_tree if reload
    u
  end
  
  def destroy_unit(unit)
    unit.terminate
    unit.disconnect
    if @selected && @selected.unit == unit
      select_other_and_destroy(unit)
    else
      @units.delete(unit)
      reload_tree
      adjust_selection
    end
  end
  
  def create_channel(unit, seed, reload=true, adjust=true)
    c = unit.find_channel(seed.name)
    return c if c
    
    @channel_id += 1
    c = IRCChannel.alloc.init
    c.id = @channel_id
    c.unit = unit
    c.pref = @pref
    c.log = create_log(unit)
    c.setup(seed)
    
    case seed.type
    when :channel
      n = unit.channels.index {|i| i.talk? }
      if n
        unit.channels.insert(n, c)
      else
        unit.channels << c
      end
    when :talk
      n = unit.channels.index {|i| i.dccchat? }
      if n
        unit.channels.insert(n, c)
      else
        unit.channels << c
      end
    when :dccchat
      unit.channels << c
    end
    
    reload_tree if reload
    adjust_selection if adjust
    expand_unit(unit) if unit.login? && unit.channels.size == 1
    c
  end
  
  def create_talk(unit, nick)
    c = create_channel(unit, IRCChannelConfig.new({:name => nick, :type => :talk}))
    if unit.login?
      c.activate
      c.add_member(User.new(unit.mynick))
      c.add_member(User.new(nick))
    end
    c
  end
  
  def destroy_channel(channel)
    channel.terminate
    unit = channel.unit
    case channel.type
    when :channel
      unit.part_channel(channel) if unit.login? && channel.active?
    when :talk
    when :dccchat
    end
    if unit.last_selected_channel == channel
      unit.last_selected_channel = nil
    end
    if @selected == channel
      select_other_and_destroy(channel)
    else
      unit.channels.delete(channel)
      reload_tree
      adjust_selection
    end
  end
  
  def adjust_selection
    row = @tree.selectedRow
    if row >= 0 && @selected && @selected != @tree.itemAtRow(row)
      @tree.select(@tree.rowForItem(@selected))
      reload_tree
    end
  end
  
  def input_text(s, cmd)
    return false unless @selected
    @selected.unit.input_text(s, cmd)
  end
  
  def select_text
    @text.focus
  end
  
  def select(item)
    select_text
    unless item
      @selected = nil
      @log_base.setContentView(@dummylog.view)
      @member_list.setDataSource(nil)
      @member_list.reloadData
      @tree.setMenu(@tree_menu)
      return
    end
    @tree.expandItem(item.unit) unless item.unit?
    i = @tree.rowForItem(item)
    return if i < 0
    @tree.select(i)
    item.unit.last_selected_channel = item.unit? ? nil : item
  end
  
  def select_channel_at(n)
    return unless @selected
    unit = @selected.unit
    return select(unit) if n == 0
    n -= 1
    channel = unit.channels[n]
    select(channel) if channel
  end
  
  def expand_unit(unit)
    @tree.expandItem(unit)
  end
  
  def update_unit_title(unit)
    return unless unit && @selected
    update_title if @selected.unit == unit
  end
  
  def update_channel_title(channel)
    return unless channel
    update_title if @selected == channel
  end
  
  def update_title
    if @selected
      sel = @selected
      if sel.unit?
        u = sel
        nick = u.mynick
        mymode = u.mymode.to_s
        name = u.config.name
        title =
          if nick.empty?
            "#{name}"
          elsif mymode.empty?
            "(#{nick}) #{name}"
          else
            "(#{nick}) (#{mymode}) #{name}"
          end
        @window.setTitle(title)
      else
        u = sel.unit
        c = sel
        nick = u.mynick
        chname = c.name
        count = c.count_members
        mode = c.mode.masked_str
        topic = c.topic
        if topic =~ /\A(.{25})/
          topic = $1 + '...'
        end
        title =
          if c.channel?
            op = c.op? ? '@' : ''
            if mode.empty?
              if count <= 1
                "(#{nick}) #{op}#{chname} #{topic}"
              else
                "(#{nick}) #{op}#{chname} (#{count}) #{topic}"
              end
            else
              if count <= 1
                "(#{nick}) #{op}#{chname} (#{mode}) #{topic}"
              else
                "(#{nick}) #{op}#{chname} (#{count},#{mode}) #{topic}"
              end
            end
          else
            "(#{nick}) #{chname}"
          end
        @window.setTitle(title)
      end
    end
  end
  
  def reload_tree
    if @reloading_tree
      @tree.setNeedsDisplay(true)
      return
    end
    @reloading_tree = true
    @tree.reloadData
    @reloading_tree = false
  end
  
  def register_growl
    @growl.register if @pref.gen.use_growl
  end
  
  def notify_on_growl(kind, title, desc, context=nil)
    @growl.notify(kind, title, desc, context) if @pref.gen.use_growl
  end
  
  def reload_log_theme
    @logtheme.theme = @pref.theme.log_theme
        
    @units.each do |u|
      u.log.reload_theme
      u.channels.each do |c|
        c.log.reload_theme
      end
    end
    @console.reload_theme
    
    #sel = selected
    #@log_base.setContentView(sel.log.view) if sel
    #@console_base.setContentView(@console.view)
  end
  
  def preferences_changed
    register_growl
    @units.each {|u| u.preferences_changed}
    reload_log_theme
  end
  
  def date_changed
    @units.each {|u| u.date_changed}
  end
  
  # delegate
  
  def outlineView_doubleClicked(sender)
    return unless @selected
    u, c = sel
    unless c
      if u.connecting? || u.connected? || u.login?
        u.quit if @pref.gen.disconnect_on_doubleclick
      else
        u.connect if @pref.gen.connect_on_doubleclick
      end
    else
      if u.login?
        if c.active?
          u.part_channel(c) if @pref.gen.leave_on_doubleclick
        else
          u.join_channel(c) if @pref.gen.join_on_doubleclick
        end
      end
    end
  end
  
  def outlineView_shouldEditTableColumn_item(sender, column, item)
    false
  end
  
  def outlineViewSelectionDidChange(notification)
    selitem = @tree.itemAtRow(@tree.selectedRow)
    unless selitem
      @log_base.setContentView(@dummylog.view)
      @tree.setMenu(@tree_menu)
      @member_list.setDataSource(nil)
      @member_list.reloadData
      return
    end
    selitem.reset_state
    @selected = selitem
    @log_base.setContentView(selitem.log.view)
    if selitem.unit?
      @tree.setMenu(@server_menu.submenu)
      @member_list.setDataSource(nil)
      @member_list.reloadData
      selitem.last_selected_channel = nil
    else
      @tree.setMenu(@channel_menu.submenu)
      @member_list.setDataSource(selitem)
      @member_list.reloadData
      selitem.unit.last_selected_channel = selitem
    end
    @member_list.deselectAll(self)
    @member_list.scrollRowToVisible(0)
    update_title
    reload_tree
  end
  
  def outlineViewItemDidCollapse(notification)
    item = notification.userInfo.objectForKey('NSObject')
    select(item) if item
  end
  
  # data source
  
  def outlineView_numberOfChildrenOfItem(sender, item)
    return @units.size unless item
    item.number_of_children
  end
  
  def outlineView_isItemExpandable(sender, item)
    item.number_of_children > 0
  end
  
  def outlineView_child_ofItem(sender, index, item)
    return @units[index] unless item
    item.child_at(index)
  end
  
  def outlineView_objectValueForTableColumn_byItem(sender, column, item)
    item.label
  end
  
  # tree
  
  def serverTreeView_acceptFirstResponder
    select_text
  end
  
  def outlineView_willDisplayCell_forTableColumn_item(sender, cell, col, item)
    if item.keyword
      textcolor = NSColor.magentaColor
    elsif item.newtalk
      textcolor = NSColor.redColor
    elsif item.unread
      textcolor = NSColor.blueColor
    elsif item.unit? ? item.login? : item.active?
      #if item == @tree.itemAtRow(@tree.selectedRow) && NSApp.isActive
      #  textcolor = NSColor.whiteColor
      #else
        textcolor = NSColor.blackColor
      #end
    else
      if item == @tree.itemAtRow(@tree.selectedRow)
        textcolor = NSColor.grayColor
      else
        textcolor = NSColor.lightGrayColor
      end
    end
    cell.setTextColor(textcolor)
    
    #textcolor = NSColor.colorWithCalibratedRed_green_blue_alpha(0.5,0.5,0.5,1.0)
    #cell.setDrawsBackground(true)
    #cell.setBackgroundColor(NSColor.whiteColor)
  end
  
  #def outlineView_willDisplayOutlineCell_forTableColumn_item(sender, cell, col, item)
  #end
  
  # log view
  
  def log_doubleClick(s)
    ary = s.split(' ')
    case ary[0]
    when 'unit'
      uid = ary[1].to_i
      unit = find_unit_by_id(uid)
      select(unit) if unit
    when 'channel'
      uid = ary[1].to_i
      cid = ary[2].to_i
      channel = find_channel_by_id(uid, cid)
      select(channel) if channel
    end
  end
  
  def log_keyDown(e)
    @window.makeFirstResponder(@text)
    select_text
    case e.keyCode.to_i
    when 36,76  # enter / num_enter
      ;
    else
      @window.sendEvent(e)
    end
  end
  
  # list view
  
  def memberListView_keyDown(e)
    @window.makeFirstResponder(@text)
    select_text
    case e.keyCode.to_i
    when 36,76  # enter / num_enter
      ;
    else
      @window.sendEvent(e)
    end
  end
  
  # timer
  
  def on_timer
    @units.each {|u| u.on_timer }
    @dcc.on_timer
    
    date = Date.today
    if @today != date
      @today = date
      date_changed
    end
  end
  
  private
  
  def select_other_and_destroy(target)
    if target.unit?
      i = @units.index(target)
      sel = @units[i+1]
      i = @tree.rowForItem(target)
    else
      i = @tree.rowForItem(target)
      sel = @tree.itemAtRow(i+1)
    end
    if sel
      select(sel)
    else
      sel = @tree.itemAtRow(i-1)
      if sel
        select(sel)
      else
        select(nil)
      end
    end
    if target.unit?
      target.channels.each {|c| c.close_dialogs }
      @units.delete(target)
    else
      target.unit.channels.delete(target)
    end
    reload_tree
    if @selected
      i = @tree.rowForItem(sel)
      @tree.select(i, true)
    end
  end
  
  def create_log(unit, console=false)
    log = LogController.alloc.init
    log.menu = console ? @console_menu : @log_menu
    log.url_menu = @url_menu
    log.addr_menu = @addr_menu
    log.member_menu = @member_menu
    log.world = self
    log.unit = unit
    log.keyword = @pref.key
    log.theme = @logtheme
    log.setup(console)
    log.view.setHostWindow(@window)
    log
  end
  
end
